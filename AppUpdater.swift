import AppKit
import Combine
import CryptoKit
import Foundation
import Darwin
import zlib

struct AppUpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AppUpdateVersion: Comparable, Equatable, Sendable {
    let parts: [Int]
    init(_ string: String) throws {
        let text = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              pieces.allSatisfy({ Int($0).map { $0 >= 0 && $0 <= 999999 } ?? false }) else { throw AppUpdateFailure("Неподдерживаемая версия: \(string)") }
        parts = pieces.map { Int($0)! } + Array(repeating: 0, count: 3 - pieces.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct AppUpdateRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int
        let digest: String?
        let browser_download_url: String
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
}

/// URLSession delegates use one serial queue. The completion is consumed once
/// under a lock; cancellation only calls URLSession's thread-safe cancellation.
private final class AppUpdateHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let hosts: Set<String>
    private let progress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var data = Data()
    private var expected: Int64 = -1
    init(limit: Int, hosts: Set<String>, progress: @escaping @Sendable (Double?) -> Void = { _ in }) {
        self.limit = limit; self.hosts = hosts; self.progress = progress
    }
    private func allowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil && hosts.contains(url.host?.lowercased() ?? "")
    }
    static func request(_ request: URLRequest, limit: Int, hosts: Set<String>, progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws -> Data {
        for attempt in 0...1 {
            do { return try await AppUpdateHTTP(limit: limit, hosts: hosts, progress: progress).fetch(request) }
            catch let error as URLError where attempt == 0 && [.networkConnectionLost, .timedOut, .cannotConnectToHost].contains(error.code) {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw AppUpdateFailure("Не удалось загрузить обновление")
    }
    func fetch(_ request: URLRequest) async throws -> Data {
        guard allowed(request.url) else { throw AppUpdateFailure("Недопустимый адрес обновления") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); self.continuation = continuation; lock.unlock()
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
                configuration.httpMaximumConnectionsPerHost = 1
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                lock.lock(); self.session = session; lock.unlock()
                if Task.isCancelled { complete(.failure(CancellationError())); return }
                session.dataTask(with: request).resume()
            }
        } onCancel: { self.complete(.failure(CancellationError())) }
    }
    private func complete(_ result: Result<Data, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil; lock.unlock()
        continuation?.resume(with: result); session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard allowed(request.url) else { completionHandler(nil); complete(.failure(AppUpdateFailure("Недопустимое перенаправление загрузки"))); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard allowed(response.url), let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); complete(.failure(AppUpdateFailure("GitHub не вернул допустимое обновление (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"))); return
        }
        expected = response.expectedContentLength; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= limit - data.count else { complete(.failure(AppUpdateFailure("Загрузка превышает лимит 20 МиБ"))); return }
        data.append(chunk)
        progress(expected > 0 ? min(1, Double(data.count) / Double(expected)) : nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(.failure(error)) } else { complete(.success(data)) }
    }
}

enum AppUpdateCore {
    static let downloadLimit = 20 * 1024 * 1024
    static let expandedLimit = 100 * 1024 * 1024
    static let entryLimit = 10000
    static func selectedAsset(_ data: Data, appName: String, repository: String, installed: String) throws -> (String, AppUpdateRelease.Asset) {
        guard data.count <= 1024 * 1024 else { throw AppUpdateFailure("Ответ GitHub слишком большой") }
        let release = try JSONDecoder().decode(AppUpdateRelease.self, from: data)
        let version = try AppUpdateVersion(release.tag_name), current = try AppUpdateVersion(installed)
        guard !release.draft, !release.prerelease else { throw AppUpdateFailure("GitHub вернул предварительный выпуск") }
        guard version > current else { throw AppUpdateFailure("Установлена актуальная версия \(installed)") }
        let plain = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let name = "\(appName)-\(plain)-macOS-arm64.zip"
        let matches = release.assets.filter { $0.name == name }
        guard matches.count == 1, let asset = matches.first, asset.size > 0, asset.size <= downloadLimit,
              let digest = asset.digest, digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).allSatisfy({ $0.isHexDigit }),
              let url = URL(string: asset.browser_download_url), url.scheme == "https", url.host == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/\(repository)/releases/download/\(release.tag_name)/\(name)" else { throw AppUpdateFailure("В выпуске нет проверяемого ZIP для macOS arm64") }
        return (plain, asset)
    }
    static func verifyDownload(_ data: Data, asset: AppUpdateRelease.Asset) throws {
        guard data.count == asset.size, data.count <= downloadLimit else { throw AppUpdateFailure("Размер загрузки не совпадает с GitHub") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard asset.digest?.lowercased() == "sha256:" + digest else { throw AppUpdateFailure("Контрольная сумма обновления не совпадает") }
    }
    struct ZIPEntry {
        let path: String
        let directory: Bool
        let executable: Bool
        let method: UInt16
        let crc: UInt32
        let offset: Int
        let compressed: Int
        let expanded: Int
    }
    static func zipEntries(_ data: Data, appName: String) throws -> [ZIPEntry] {
        func fail() -> AppUpdateFailure { AppUpdateFailure("Небезопасный или неподдерживаемый ZIP") }
        guard data.count >= 22, data.count <= downloadLimit else { throw fail() }
        func u16(_ i: Int) throws -> UInt16 { guard i >= 0, i + 2 <= data.count else { throw fail() }; return UInt16(data[i]) | UInt16(data[i + 1]) << 8 }
        func u32(_ i: Int) throws -> UInt32 { UInt32(try u16(i)) | UInt32(try u16(i + 2)) << 16 }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try u32(i) == 0x06054b50, i + 22 + Int(try u16(i + 20)) == data.count { end = i; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw fail() }
        let count = Int(try u16(end + 10)), centralSize = Int(try u32(end + 12)), centralStart = Int(try u32(end + 16))
        guard count > 0, count <= entryLimit, count == Int(try u16(end + 8)), centralStart + centralSize == end else { throw fail() }
        var cursor = centralStart, total = 0, entries: [ZIPEntry] = [], names = Set<String>(), files = Set<String>()
        for _ in 0..<count {
            guard try u32(cursor) == 0x02014b50 else { throw fail() }
            let flags = try u16(cursor + 8), method = try u16(cursor + 10)
            let compressed = Int(try u32(cursor + 20)), expanded = Int(try u32(cursor + 24))
            let nameLength = Int(try u16(cursor + 28)), extraLength = Int(try u16(cursor + 30)), commentLength = Int(try u16(cursor + 32))
            guard flags & 1 == 0, [0, 8].contains(method), try u16(cursor + 34) == 0,
                  cursor + 46 + nameLength + extraLength + commentLength <= end,
                  let name = String(data: data[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8) else { throw fail() }
            let directory = name.hasSuffix("/"), path = directory ? String(name.dropLast()) : name
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.first == Substring(appName + ".app"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !path.contains("\\"), !path.contains(":"), !path.contains("\0"), !(components.count == 1 && !directory) else { throw fail() }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(key).inserted else { throw fail() }
            if !directory { files.insert(key) }
            let attributes = try u32(cursor + 38), mode = UInt16(attributes >> 16), kind = mode & 0o170000
            guard kind == 0 || kind == 0o100000 || (kind == 0o040000 && directory), !(directory && (compressed != 0 || expanded != 0)) else { throw fail() }
            var extra = cursor + 46 + nameLength
            while extra < cursor + 46 + nameLength + extraLength {
                let tag = try u16(extra), length = Int(try u16(extra + 2))
                guard ![UInt16(0x0001), 0x000d, 0x756e, 0x7075].contains(tag), extra + 4 + length <= cursor + 46 + nameLength + extraLength else { throw fail() }
                extra += 4 + length
            }
            total += expanded
            guard total <= expandedLimit, compressed <= downloadLimit, expanded <= expandedLimit else { throw fail() }
            let local = Int(try u32(cursor + 42))
            guard try u32(local) == 0x04034b50, try u16(local + 6) == flags, try u16(local + 8) == method else { throw fail() }
            let localName = Int(try u16(local + 26)), localExtra = Int(try u16(local + 28)), offset = local + 30 + localName + localExtra
            let localCompressed = Int(try u32(local + 18)), localExpanded = Int(try u32(local + 22))
            guard localName == nameLength, local + 30 + localName <= centralStart,
                  data[(local + 30)..<(local + 30 + localName)] == data[(cursor + 46)..<(cursor + 46 + nameLength)], offset + compressed <= centralStart,
                  flags & 8 != 0 || (localCompressed == compressed && localExpanded == expanded) else { throw fail() }
            entries.append(ZIPEntry(path: path, directory: directory, executable: mode & 0o111 != 0, method: method, crc: try u32(cursor + 16), offset: offset, compressed: compressed, expanded: expanded))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard cursor == end else { throw fail() }
        for entry in entries {
            let components = entry.path.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
            for length in 1..<components.count { if files.contains(components.prefix(length).joined(separator: "/")) { throw fail() } }
        }
        let ranges = entries.filter { !$0.directory }.sorted { $0.offset < $1.offset }
        for i in ranges.indices.dropFirst() { guard ranges[i - 1].offset + ranges[i - 1].compressed <= ranges[i].offset else { throw fail() } }
        return entries
    }
    static func extract(_ data: Data, appName: String, to directory: URL) throws -> URL {
        let entries = try zipEntries(data, appName: appName), fm = FileManager.default
        guard !fm.fileExists(atPath: directory.path) else { throw AppUpdateFailure("Каталог распаковки уже существует") }
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for entry in entries {
                let target = directory.appendingPathComponent(entry.path)
                if entry.directory { try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]); continue }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                guard fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: entry.executable ? 0o755 : 0o644]) else { throw AppUpdateFailure("Не удалось распаковать файл") }
                let output = try FileHandle(forWritingTo: target)
                do { try inflateEntry(data, entry: entry) { try output.write(contentsOf: $0) }; try output.close() }
                catch { try? output.close(); throw error }
            }
            return directory.appendingPathComponent(appName + ".app")
        } catch { try? fm.removeItem(at: directory); throw error }
    }
    private static func inflateEntry(_ data: Data, entry: ZIPEntry, write: (Data) throws -> Void) throws {
        var count = 0, crc = crc32(0, nil, 0)
        func emit(_ bytes: UnsafePointer<UInt8>, _ length: Int) throws {
            guard length <= entry.expanded - count else { throw AppUpdateFailure("ZIP превышает заявленный размер") }
            count += length; crc = crc32(crc, bytes, uInt(length)); try write(Data(bytes: bytes, count: length))
        }
        try data.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: entry.offset)
            if entry.method == 0 { try emit(input, entry.compressed) }
            else {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw AppUpdateFailure("Ошибка распаковки ZIP") }
                defer { inflateEnd(&stream) }
                stream.next_in = UnsafeMutablePointer(mutating: input); stream.avail_in = uInt(entry.compressed)
                var buffer = [UInt8](repeating: 0, count: 65536)
                try buffer.withUnsafeMutableBufferPointer { output in
                    while true {
                        stream.next_out = output.baseAddress!; stream.avail_out = uInt(output.count)
                        let result = inflate(&stream, Z_NO_FLUSH), produced = output.count - Int(stream.avail_out)
                        try emit(output.baseAddress!, produced)
                        if result == Z_STREAM_END { break }
                        guard result == Z_OK, produced > 0 || stream.avail_in > 0 else { throw AppUpdateFailure("Повреждённый ZIP") }
                    }
                }
                guard stream.avail_in == 0 else { throw AppUpdateFailure("Лишние данные в ZIP") }
            }
        }
        guard count == entry.expanded, UInt32(crc) == entry.crc else { throw AppUpdateFailure("Повреждённый файл обновления") }
    }
    @discardableResult static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdateFailure(String(data: data.prefix(4096), encoding: .utf8) ?? "Ошибка системной проверки") }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func bundleVersion(_ app: URL, identifier: String) throws -> String {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == identifier, info["CFBundlePackageType"] as? String == "APPL",
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/"), executable != ".", executable != "..",
              let version = info["CFBundleShortVersionString"] as? String else { throw AppUpdateFailure("Неверное приложение в обновлении") }
        _ = try AppUpdateVersion(version)
        guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/" + executable).path) else { throw AppUpdateFailure("Нет исполняемого файла приложения") }
        return version
    }
    static func validateBundle(_ app: URL, configuration: AppUpdater.Configuration, version: String, installed: URL) throws {
        let fm = FileManager.default
        guard try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppUpdateFailure("Приложение не должно быть ссылкой") }
        guard let walker = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) else { throw AppUpdateFailure("Нет файлов обновления") }
        var count = 0, bytes = 0
        for case let file as URL in walker {
            let properties = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard properties.isSymbolicLink != true, properties.isRegularFile == true || properties.isDirectory == true else { throw AppUpdateFailure("Обновление содержит ссылки или специальные файлы") }
            count += 1; bytes += properties.isRegularFile == true ? (properties.fileSize ?? 0) : 0
            guard count <= entryLimit, bytes <= expandedLimit else { throw AppUpdateFailure("Распакованное обновление слишком большое") }
        }
        guard try bundleVersion(app, identifier: configuration.bundleIdentifier) == version else { throw AppUpdateFailure("Версия приложения не совпадает с выпуском") }
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        guard let minimum = info["LSMinimumSystemVersion"] as? String else { throw AppUpdateFailure("В обновлении не указана версия macOS") }
        do {
            let required = try AppUpdateVersion(minimum).parts, os = ProcessInfo.processInfo.operatingSystemVersion
            if [os.majorVersion, os.minorVersion, os.patchVersion].lexicographicallyPrecedes(required) { throw AppUpdateFailure("Для обновления нужна macOS \(minimum)") }
        }
        if let platforms = info["CFBundleSupportedPlatforms"] as? [String], !platforms.contains("MacOSX") { throw AppUpdateFailure("Обновление предназначено не для macOS") }
        guard Bundle(url: app)?.executableArchitectures?.contains(NSNumber(value: 0x0100000c)) == true else { throw AppUpdateFailure("Обновление не поддерживает Apple Silicon") }
        try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let oldSignature = try command("/usr/bin/codesign", ["-d", "--verbose=4", installed.path])
        let newSignature = try command("/usr/bin/codesign", ["-d", "--verbose=4", app.path])
        guard newSignature.split(separator: "\n").contains("Identifier=" + configuration.bundleIdentifier) else { throw AppUpdateFailure("Идентификатор подписи не совпадает") }
        let team = oldSignature.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
        if let team, team != "TeamIdentifier=not set", !newSignature.split(separator: "\n").contains(team) { throw AppUpdateFailure("Подпись разработчика изменилась") }
    }
    /// NSRunningApplication refreshes its state on main run-loop turns.
    /// Pump that loop while waiting; sleeping here would cache stale launch state.
    static func launchAndWait(_ app: URL, identifier: String, arguments: [String], timeout: TimeInterval = 15, stability: TimeInterval = 2) throws {
        try command("/usr/bin/open", ["-g", "-n", "-a", app.path, "--args"] + arguments)
        let limit = Date().addingTimeInterval(timeout)
        var readySince: Date?
        while Date() < limit {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first { $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL == app.standardizedFileURL && !$0.isTerminated && $0.isFinishedLaunching }
            if running != nil { if readySince == nil { readySince = Date() }; if Date().timeIntervalSince(readySince!) >= stability { return } } else { readySince = nil }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }
        running.forEach { _ = $0.terminate() }
        let stopping = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }) && Date() < stopping { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        throw AppUpdateFailure("Не удалось запустить обновлённое приложение")
    }
    static func exchange(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { a in second.path.withCString { b in renameatx_np(AT_FDCWD, a, AT_FDCWD, b, UInt32(RENAME_SWAP)) } }
        guard result == 0 else { throw AppUpdateFailure("Не удалось заменить приложение: \(String(cString: strerror(errno)))") }
    }
    static func install(current: URL, staged: URL, canRollback: () -> Bool = { true }, launch: (URL) throws -> Void) throws {
        try exchange(current, staged)
        do { try launch(current) }
        catch {
            guard canRollback() else { throw AppUpdateFailure("Новое приложение не завершилось. Прежняя версия сохранена в \(staged.path)") }
            do { try exchange(current, staged) } catch { throw AppUpdateFailure("Не удалось восстановить прежнее приложение: \(error.localizedDescription)") }
            throw AppUpdateFailure("Новое приложение не запустилось. Прежняя версия восстановлена.")
        }
    }
}

@MainActor final class AppUpdater: ObservableObject {
    struct Configuration: Sendable {
        let repository: String
        let appName: String
        let bundleIdentifier: String
        let relaunchArguments: [String]
    }
    @Published private(set) var status = "Проверка обновлений запускается вручную"
    @Published private(set) var busy = false
    @Published private(set) var progress: Double?
    private let configuration: Configuration
    init(configuration: Configuration) {
        self.configuration = configuration
        if let error = try? String(contentsOf: Self.reportURL(configuration), encoding: .utf8) { status = error }
    }
    private static func reportURL(_ configuration: Configuration) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(configuration.bundleIdentifier + "-update-error.txt")
    }
    private struct Plan: Codable, Sendable {
        let current: URL
        let staged: URL
        let work: URL
        let version: String
        let pid: Int32
    }
    private static func valid(_ configuration: Configuration) -> Bool {
        [("DmitryBarmin/NotchHub", "NotchHub", "local.notchhub.app"), ("DmitryBarmin/GlassDock", "GlassDock", "local.glassdock.app")]
            .contains { $0.0 == configuration.repository && $0.1 == configuration.appName && $0.2 == configuration.bundleIdentifier }
    }
    func update() {
        guard !busy else { return }
        busy = true; progress = nil; status = "Проверяю GitHub…"
        let configuration = self.configuration, current = Bundle.main.bundleURL
        Task {
            var work: URL?
            do {
                guard Self.valid(configuration), current.pathExtension == "app", FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else { throw AppUpdateFailure("Приложение должно быть установлено в доступную для записи папку «Программы»") }
                var arm64: Int32 = 0, arm64Size = MemoryLayout<Int32>.size
                guard sysctlbyname("hw.optional.arm64", &arm64, &arm64Size, nil, 0) == 0, arm64 == 1 else { throw AppUpdateFailure("Автообновление поддерживает только Apple Silicon") }
                let installed = try AppUpdateCore.bundleVersion(current, identifier: configuration.bundleIdentifier)
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(configuration.repository)/releases/latest")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept"); request.setValue(configuration.appName + "-Updater", forHTTPHeaderField: "User-Agent")
                let metadata = try await AppUpdateHTTP.request(request, limit: 1024 * 1024, hosts: ["api.github.com"])
                let (version, asset) = try AppUpdateCore.selectedAsset(metadata, appName: configuration.appName, repository: configuration.repository, installed: installed)
                status = "Загружаю \(version)…"; progress = 0
                let zip = try await AppUpdateHTTP.request(URLRequest(url: URL(string: asset.browser_download_url)!), limit: AppUpdateCore.downloadLimit, hosts: ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"], progress: { [weak self] value in Task { @MainActor in self?.progress = value } })
                status = "Проверяю и подготавливаю обновление…"; progress = nil
                let prepared = try await Task.detached(priority: .utility) {
                    try AppUpdateCore.verifyDownload(zip, asset: asset)
                    let directory = current.deletingLastPathComponent().appendingPathComponent(".\(configuration.appName)-update-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    do {
                        let staged = try AppUpdateCore.extract(zip, appName: configuration.appName, to: directory.appendingPathComponent("payload"))
                        try AppUpdateCore.validateBundle(staged, configuration: configuration, version: version, installed: current)
                        return (directory, staged)
                    } catch { try? FileManager.default.removeItem(at: directory); throw error }
                }.value
                work = prepared.0
                let plan = Plan(current: current, staged: prepared.1, work: prepared.0, version: version, pid: getpid())
                let planURL = prepared.0.appendingPathComponent("plan.json")
                try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: planURL.path)
                guard let executable = Bundle.main.executableURL else { throw AppUpdateFailure("Не найден помощник обновления") }
                let helper = Process(); helper.executableURL = executable; helper.arguments = ["--apply-update", planURL.path]
                helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
                try helper.run()
                status = "Устанавливаю обновление…"; NSApp.terminate(nil)
            } catch {
                if let work { try? FileManager.default.removeItem(at: work) }
                status = error.localizedDescription; progress = nil; busy = false
            }
        }
    }
    static func runHelperIfRequested(configuration: Configuration) -> Bool {
        let args = CommandLine.arguments
        guard args.count > 1, args[1] == "--apply-update" else { return false }
        guard args.count == 3, valid(configuration) else { exit(2) }
        var validatedPlan: Plan?
        do {
            let planURL = URL(fileURLWithPath: args[2]).standardizedFileURL
            let attributes = try FileManager.default.attributesOfItem(atPath: planURL.path)
            guard attributes[.ownerAccountID] as? UInt32 == getuid(), attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.posixPermissions] as? Int ?? 0) & 0o077 == 0,
                  (attributes[.size] as? Int ?? 0) <= 16384 else { throw AppUpdateFailure("Неверный план обновления") }
            let decoded = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: planURL))
            let current = Bundle.main.bundleURL.standardizedFileURL
            guard decoded.current.standardizedFileURL == current, decoded.pid > 1,
                  decoded.work.deletingLastPathComponent().standardizedFileURL == current.deletingLastPathComponent(),
                  decoded.work.lastPathComponent.hasPrefix(".\(configuration.appName)-update-"),
                  planURL == decoded.work.appendingPathComponent("plan.json").standardizedFileURL,
                  decoded.staged.standardizedFileURL == decoded.work.appendingPathComponent("payload/\(configuration.appName).app").standardizedFileURL,
                  decoded.work.resolvingSymlinksInPath() == decoded.work.standardizedFileURL else { throw AppUpdateFailure("Неверные пути обновления") }
            let workAttributes = try FileManager.default.attributesOfItem(atPath: decoded.work.path)
            guard workAttributes[.ownerAccountID] as? UInt32 == getuid(), workAttributes[.type] as? FileAttributeType == .typeDirectory,
                  (workAttributes[.posixPermissions] as? Int ?? 0) & 0o077 == 0,
                  try AppUpdateVersion(decoded.version) > AppUpdateVersion(AppUpdateCore.bundleVersion(current, identifier: configuration.bundleIdentifier)) else { throw AppUpdateFailure("Неверный каталог или версия обновления") }
            validatedPlan = decoded
            try AppUpdateCore.validateBundle(decoded.staged, configuration: configuration, version: decoded.version, installed: current)
            let deadline = Date().addingTimeInterval(45)
            while kill(decoded.pid, 0) == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            guard kill(decoded.pid, 0) != 0, errno == ESRCH else { throw AppUpdateFailure("Приложение не завершилось — обновление отменено") }
            try AppUpdateCore.install(current: current, staged: decoded.staged, canRollback: {
                !NSRunningApplication.runningApplications(withBundleIdentifier: configuration.bundleIdentifier).contains { $0.processIdentifier != getpid() && !$0.isTerminated }
            }) { app in
                try AppUpdateCore.launchAndWait(app, identifier: configuration.bundleIdentifier, arguments: configuration.relaunchArguments)
            }
            try? FileManager.default.removeItem(at: reportURL(configuration)); try? FileManager.default.removeItem(at: decoded.work)
            exit(0)
        } catch {
            let message = "Обновление не установлено: " + error.localizedDescription
            try? message.write(to: reportURL(configuration), atomically: true, encoding: .utf8)
            if let plan = validatedPlan, plan.current.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
                // Remove the rejected new payload only if the old app is still/restored
                // at its original location. A failed rollback must retain its backup.
                if let currentVersion = try? AppUpdateCore.bundleVersion(plan.current, identifier: configuration.bundleIdentifier), currentVersion != plan.version {
                    try? FileManager.default.removeItem(at: plan.work)
                }
                _ = try? AppUpdateCore.command("/usr/bin/open", ["-g", "-a", plan.current.path, "--args"] + configuration.relaunchArguments)
            }
            exit(1)
        }
    }
}
