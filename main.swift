import AppKit
import ApplicationServices
import ScreenCaptureKit
import Combine

private let glassDockUpdateConfiguration = AppUpdater.Configuration(
    repository: "DmitryBarmin/GlassDock", appName: "GlassDock",
    bundleIdentifier: "local.glassdock.app", relaunchArguments: ["--background"]
)

private func ax<T>(_ element: AXUIElement, _ name: String) -> T? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result as? T
}

// Private but long-stable AX SPI (used by AltTab, DockDoor): the window server ID of an AX window.
// Geometry/title matching cannot tell apart stacked windows with equal frames and titles.
@_silgen_name("_AXUIElementGetWindow") private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

private func axWindowID(_ element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
}

private func axRect(_ element: AXUIElement) -> CGRect? {
    guard let p: AXValue = ax(element, kAXPositionAttribute), let s: AXValue = ax(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

private func cocoaRect(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY, width: rect.width, height: rect.height)
}

private struct WindowRecord {
    let id: CGWindowID
    let pid: pid_t
    let window: SCWindow
    let element: AXUIElement?
    let minimized: Bool
}

@MainActor private final class WindowStore {
    let screenshotBackground = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
    var records: [CGWindowID: WindowRecord] = [:]
    var images = ThumbnailCache<NSImage>(capacity: 96, byteLimit: 24 * 1024 * 1024)
    var order = WindowOrder()
    var observers: [pid_t: AXObserver] = [:]
    var observedWindows: [pid_t: [AXUIElement]] = [:]
    var refreshing = false
    var captureBusy = false
    var onChange: (() -> Void)?
    var thumbnailWidth: CGFloat = 230
    var lastInventory = Date.distantPast
    var inventoryPending = false
    var captureQueue: [CGWindowID: CGFloat] = [:]
    var captureThrottle = WorkThrottle()
    var inventoryCount = 0
    var captureCount = 0
    var suspended = false

    func refreshFocusedThumbnail() async {
        guard let id = order.lastFocused, let record = records[id],
              let app = NSWorkspace.shared.frontmostApplication,
              shouldRefreshForegroundThumbnail(suspended: suspended, busy: captureBusy, minimized: record.minimized,
                                               owner: record.pid, frontmost: app.processIdentifier, hidden: app.isHidden) else { return }
        await capture([id], width: thumbnailWidth)
    }

    func clearPrivateCache() {
        images.removeAll(); records.removeAll(); captureQueue.removeAll()
        order.prune(live: [])
        lastInventory = .distantPast
        onChange?()
    }

    func warmMissing(pid: pid_t? = nil) async {
        let ids = order.sorted(records.values.filter {
            (pid == nil || $0.pid == pid) && !$0.minimized && $0.window.isOnScreen && images[$0.id] == nil
        }.map(\.id))
        let estimatedBytes = max(1, Int(thumbnailWidth * 2) * Int(thumbnailWidth * 2 * 0.64) * 4)
        let warmCount = min(96, max(1, images.byteLimit / estimatedBytes))
        await capture(Array(ids.prefix(warmCount)), width: thumbnailWidth)
    }

    func match(_ element: AXUIElement, pid: pid_t) -> CGWindowID? {
        if let id = axWindowID(element), records[id]?.pid == pid { return id }
        let title: String = ax(element, kAXTitleAttribute) ?? ""
        let rect = axRect(element)
        let candidates = records.values.filter { $0.pid == pid }
        if let exact = candidates.first(where: { $0.element.map { CFEqual($0, element) } ?? false }) { return exact.id }
        return matchingWindow(in: candidates, nativeID: nil, frame: rect, title: title,
                              id: { $0.id }, geometry: { $0.window.frame }, name: { $0.window.title })?.id
    }

    func event(_ element: AXUIElement, notification: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if notification == kAXWindowMiniaturizedNotification || notification == kAXFocusedWindowChangedNotification || notification == kAXWindowDeminiaturizedNotification {
            let target: AXUIElement = notification == kAXFocusedWindowChangedNotification
                ? (ax(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) ?? element) : element
            if let id = match(target, pid: pid) {
                if notification == kAXWindowMiniaturizedNotification {
                    order.minimize(id, pid: pid, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, time: Date.timeIntervalSinceReferenceDate)
                } else if notification == kAXFocusedWindowChangedNotification {
                    order.focus(id, pid: pid, time: Date.timeIntervalSinceReferenceDate)
                }
                if notification != kAXFocusedWindowChangedNotification, let old = records[id] {
                    records[id] = WindowRecord(id: id, pid: old.pid, window: old.window, element: old.element, minimized: notification == kAXWindowMiniaturizedNotification)
                }
                images.prioritize(id, value: order.recency[id, default: 0])
                onChange?()
                if notification != kAXWindowMiniaturizedNotification, images[id] == nil {
                    Task { await capture([id], width: thumbnailWidth) }
                }
                return
            }
        }
        Task {
            await refresh(force: true)
            await warmMissing(pid: pid)
        }
    }

    func installObserver(_ pid: pid_t, windows: [AXUIElement]) {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        if observers[pid] == nil {
            var observer: AXObserver?
            let result = AXObserverCreate(pid, { _, element, notification, pointer in
                guard let pointer else { return }
                // AX observers are attached to the main run loop.
                MainActor.assumeIsolated {
                    Unmanaged<WindowStore>.fromOpaque(pointer).takeUnretainedValue().event(element, notification: notification as String)
                }
            }, &observer)
            if result == .success, let observer {
                observers[pid] = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                let application = AXUIElementCreateApplication(pid)
                for name in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
                    AXObserverAddNotification(observer, application, name as CFString, pointer)
                }
            }
        }
        guard let observer = observers[pid] else { return }
        for window in windows where !(observedWindows[pid] ?? []).contains(where: { CFEqual($0, window) }) {
            for name in [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(observer, window, name as CFString, pointer)
            }
        }
        observedWindows[pid] = windows
    }

    func refresh(force: Bool = false) async {
        guard !suspended else { return }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { clearPrivateCache(); return }
        if refreshing { if force { inventoryPending = true }; return }
        guard force || Date().timeIntervalSince(lastInventory) >= 2 else { return }
        refreshing = true
        lastInventory = Date()
        inventoryCount += 1
        defer {
            refreshing = false
            if inventoryPending {
                inventoryPending = false
                Task { await refresh(force: true); await warmMissing() }
            }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            var next: [CGWindowID: WindowRecord] = [:]
            let grouped = Dictionary(grouping: content.windows.filter {
                $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60 &&
                $0.owningApplication?.processID != getpid()
            }, by: { $0.owningApplication?.processID ?? 0 })
            for (pid, windows) in grouped where pid != 0 {
                let application = AXUIElementCreateApplication(pid)
                let elements: [AXUIElement] = ax(application, kAXWindowsAttribute) ?? []
                installObserver(pid, windows: elements)
                var used = Set<CGWindowID>()
                for element in elements {
                    guard let rect = axRect(element) else { continue }
                    let title: String = ax(element, kAXTitleAttribute) ?? ""
                    let candidates = windows.filter { !used.contains($0.windowID) }
                    let window = matchingWindow(in: candidates, nativeID: axWindowID(element), frame: rect, title: title,
                                                id: { $0.windowID }, geometry: { $0.frame }, name: { $0.title })
                    if let window {
                        used.insert(window.windowID)
                        next[window.windowID] = WindowRecord(id: window.windowID, pid: pid, window: window, element: element, minimized: ax(element, kAXMinimizedAttribute) ?? false)
                    }
                }
                // Do not show unmatchable windows: their focus action could target the wrong window.
            }
            // ScreenCaptureKit may temporarily omit minimized windows. Keep an AX-backed cached record only while it is alive.
            for (id, old) in records where next[id] == nil {
                guard let element = old.element,
                      let minimized: Bool = ax(element, kAXMinimizedAttribute), minimized,
                      images[id] != nil else { continue }
                next[id] = WindowRecord(id: id, pid: old.pid, window: old.window, element: element, minimized: true)
            }
            let livePIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            for (pid, observer) in observers where !livePIDs.contains(pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                observers.removeValue(forKey: pid)
                observedWindows.removeValue(forKey: pid)
            }
            let changed = Set(records.keys) != Set(next.keys) || next.contains { id, record in
                records[id]?.minimized != record.minimized || records[id]?.window.frame != record.window.frame
            }
            records = next
            images.prune(live: Set(next.keys))
            order.prune(live: Set(next.keys))
            captureThrottle.prune(live: Set(next.keys))
            sampleFocus()
            if changed { onChange?() }
        } catch {
            NSLog("GlassDock: window inventory unavailable: %@", error.localizedDescription)
        }
    }

    func sampleFocus() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let element: AXUIElement? = ax(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
        if let element, let id = match(element, pid: app.processIdentifier), id != order.lastFocused {
            order.focus(id, pid: app.processIdentifier, time: Date.timeIntervalSinceReferenceDate)
            images.prioritize(id, value: order.recency[id, default: 0])
            onChange?()
        }
    }

    func explicitClick() {
        order.explicitInput()
        let point = NSEvent.mouseLocation
        let flipped = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(flipped.x), Float(flipped.y), &hit) == .success,
              var element = hit else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        for _ in 0..<12 {
            let role: String = ax(element, kAXRoleAttribute) ?? ""
            if role == kAXWindowRole, let id = match(element, pid: pid) {
                order.explicitInput(clickedWindow: id)
                images.prioritize(id, value: order.recency[id, default: 0])
                onChange?()
                return
            }
            if let window: AXUIElement = ax(element, kAXWindowAttribute) { element = window }
            else if let parent: AXUIElement = ax(element, kAXParentAttribute) { element = parent }
            else { return }
        }
    }

    func capture(_ ids: [CGWindowID], width: CGFloat) async {
        guard !suspended else { return }
        guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else { clearPrivateCache(); return }
        for id in ids { captureQueue[id] = max(captureQueue[id] ?? 0, width) }
        guard !captureBusy else { return }
        captureBusy = true
        defer { captureBusy = false; onChange?() }
        while let id = order.sorted(Array(captureQueue.keys)).first {
            guard !suspended else { break }
            let width = captureQueue.removeValue(forKey: id)!
            guard let record = records[id], !record.minimized else { continue }
            guard captureThrottle.allow(id, at: Date.timeIntervalSinceReferenceDate, interval: 0.7) else { continue }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(width * 2)
            configuration.height = max(1, Int(width * 2 * 0.64))
            configuration.backgroundColor = screenshotBackground
            configuration.showsCursor = false
            configuration.scalesToFit = true
            configuration.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: record.window)
            captureCount += 1
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                guard !suspended, let current = records[id], current.pid == record.pid, !current.minimized,
                      CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else { continue }
                images.insert(NSImage(cgImage: image, size: .zero), for: id, bytes: image.bytesPerRow * image.height, priority: order.recency[id, default: 0])
            } catch { /* Retain the last good thumbnail during transient/minimize races. */ }
        }
    }

    func windows(for pid: pid_t) -> [WindowRecord] {
        order.sorted(records.values.filter { $0.pid == pid }.map(\.id)).compactMap { records[$0] }
    }

    func focus(_ id: CGWindowID) {
        guard let record = records[id], let element = record.element else { return }
        if record.minimized { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        NSRunningApplication(processIdentifier: record.pid)?.activate(options: [])
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(record.pid), kAXFocusedWindowAttribute as CFString, element)
        order.explicitInput()
        order.focus(id, pid: record.pid, time: Date.timeIntervalSinceReferenceDate)
        images.prioritize(id, value: order.recency[id, default: 0])
    }

    @discardableResult func close(_ id: CGWindowID) -> Bool {
        guard let record = records[id], let element = record.element,
              let button: AXUIElement = ax(element, kAXCloseButtonAttribute) else { return false }
        // Press the window's own close control. Native unsaved-document prompts stay in charge.
        NSRunningApplication(processIdentifier: record.pid)?.activate(options: [])
        let accepted = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        Task { await refresh() }
        return accepted
    }
}

@MainActor private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class ThumbnailView: NSView {
    var image: NSImage?
    var action: (() -> Void)?
    var closeAction: (() -> Void)?
    var closeButtonSide = "right" { didSet { needsLayout = true } }
    var minimized = false {
        didSet { minimizedMarker.isHidden = !minimized; needsDisplay = true }
    }
    let minimizedMarker = PassthroughImageView()
    let closeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        minimizedMarker.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
        minimizedMarker.contentTintColor = .white.withAlphaComponent(0.72)
        minimizedMarker.imageScaling = .scaleProportionallyDown
        minimizedMarker.isHidden = true
        minimizedMarker.setAccessibilityElement(false)
        addSubview(minimizedMarker)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Закрыть окно")?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .white.withAlphaComponent(0.75)
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.23).cgColor
        closeButton.layer?.cornerRadius = 10
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.setAccessibilityLabel("Закрыть это окно")
        addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        minimizedMarker.frame = CGRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32)
        closeButton.frame = previewCloseButtonFrame(in: bounds, side: closeButtonSide)
    }
    @objc func closeClicked() { closeAction?() }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let inset = bounds.insetBy(dx: 1, dy: 1)
        NSBezierPath(roundedRect: inset, xRadius: 12, yRadius: 12).addClip()
        let size = image.size
        let ratio = min(inset.width / max(1, size.width), inset.height / max(1, size.height))
        let target = CGRect(x: inset.midX - size.width * ratio / 2, y: inset.midY - size.height * ratio / 2, width: size.width * ratio, height: size.height * ratio)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        if minimized {
            NSColor.black.withAlphaComponent(0.20).setFill()
            NSBezierPath(ovalIn: CGRect(x: bounds.midX - 23, y: bounds.midY - 23, width: 46, height: 46)).fill()
        }
    }
    override func mouseDown(with event: NSEvent) { action?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor private final class PreviewPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        setAccessibilityLabel("GlassDock — предпросмотр окон")
    }
    override var canBecomeKey: Bool { false }
}

@MainActor private final class SettingsGlassContainer: NSGlassEffectContainerView {
    override var isFlipped: Bool { true }
}

@MainActor private final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = WindowStore()
    let updater = AppUpdater(configuration: glassDockUpdateConfiguration)
    var updateObservation: AnyCancellable?
    var updateButton: NSButton?
    var updateStatus: NSTextField?
    var updateProgress: NSProgressIndicator?
    var panels: [PreviewPanel] = []
    var previewVisible: Bool { panels.contains { $0.isVisible } }
    var previewFrames: [CGRect] { panels.filter { $0.isVisible }.map(\.frame) }
    var status: NSStatusItem!
    var settingsWindow: NSWindow?
    var permissionsWindow: NSWindow?
    var sizeSlider: NSSlider?
    var opacitySlider: NSSlider?
    var sizeLabel: NSTextField?
    var opacityLabel: NSTextField?
    var closeSideControl: NSSegmentedControl?
    var timer: Timer?
    var cacheTimer: Timer?
    var focusedCaptureTimer: Timer?
    var mouseMonitor: Any?
    var motionMonitor: Any?
    var localMotionMonitor: Any?
    var dockOrientation = "bottom"
    var sleeping = false
    var cachedDockPoint = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    var cachedDockTarget: (pid_t, CGRect)?
    var dockProbeBudget = DockProbeBudget()
    var lastDockLookup = Date.distantPast
    var dockLookupCount = 0
    var pointerPollCount = 0
    var lastPermissionCheck = Date.distantPast
    var hoveredPID: pid_t?
    var dockRect = CGRect.zero
    var hoverBegan = Date.distantPast
    var generation = 0
    var rendering = false
    var demo = false
    var demoItems: [PreviewItem<NSImage>] = []
    var demoAnchor = CGRect.zero
    var demoExpires = Date.distantPast
    var renderedIDs: [CGWindowID] = []
    var lastRender = Date.distantPast
    var previewWidth: CGFloat { max(140, min(420, CGFloat(UserDefaults.standard.double(forKey: "previewWidth")))) }
    var previewOpacity: CGFloat { max(0.35, min(1, CGFloat(UserDefaults.standard.double(forKey: "previewOpacity")))) }
    var closeButtonSide: String { UserDefaults.standard.string(forKey: "closeButtonSide") == "left" ? "left" : "right" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["previewWidth": 230.0, "previewOpacity": 0.94, "closeButtonSide": "right"])
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "GlassDock")
        status.button?.toolTip = "GlassDock — предпросмотр окон"
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let heading = NSMenuItem(title: "GlassDock  \(version)", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        for (title, symbol, selector, key) in [
            ("Настройки…", "slider.horizontal.3", #selector(showSettings), ","),
            ("Обновить…", "arrow.triangle.2.circlepath", #selector(updateApp), ""),
            ("", "", #selector(showSettings), ""),
            ("Показать демо", "rectangle.on.rectangle", #selector(showDemo), ""),
            ("Доступы macOS…", "lock.shield", #selector(showPermissions), "")
        ] {
            if title.isEmpty { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Завершить GlassDock", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        status.menu = menu
        let mainMenu = NSMenu()
        let appMenu = NSMenuItem(title: "GlassDock", action: nil, keyEquivalent: "")
        appMenu.submenu = menu.copy() as? NSMenu
        mainMenu.addItem(appMenu)
        NSApp.mainMenu = mainMenu
        store.onChange = { [weak self] in
            guard let self, self.previewVisible, !self.demo else { return }
            // Inventory/capture completion only paints; it must never enqueue another capture cycle.
            if let pid = self.hoveredPID { self.presentCached(pid: pid) }
        }
        store.thumbnailWidth = previewWidth
        updateDockOrientation()
        cacheTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.sleeping else { return }
                self.updateDockOrientation()
                if !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() { self.store.clearPrivateCache(); self.hidePreview() }
                self.store.sampleFocus()
                if CommandLine.arguments.contains("--metrics") {
                    let line = "GlassDock metrics: inventory=\(self.store.inventoryCount) captures=\(self.store.captureCount) dockAX=\(self.dockLookupCount) pointerPolls=\(self.pointerPollCount) cacheImages=\(self.store.images.count) cacheBytes=\(self.store.images.byteCount)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
        }
        focusedCaptureTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.sleeping else { return }
                Task { await self.store.refreshFocusedThumbnail() }
            }
        }
        focusedCaptureTimer?.tolerance = 0.3
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeAppChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appLaunched), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.explicitClick() }
        }
        motionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerChanged() }
        }
        localMotionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.pointerChanged()
            return event
        }
        if CommandLine.arguments.contains("--demo") { showDemo() }
        else if !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() { showPermissions() }
        else if !CommandLine.arguments.contains("--background") { showSettings() }
        Task { await store.refresh(force: true); await store.warmMissing() }
        pointerChanged()
    }

    @objc func activeAppChanged() {
        store.sampleFocus()
        Task { await store.refresh(); await store.warmMissing(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier) }
    }
    @objc func appLaunched(_ notification: Notification) {
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            store.installObserver(application.processIdentifier, windows: [])
        }
        Task { await store.refresh(force: true); await store.warmMissing() }
    }
    @objc func appTerminated() { cachedDockTarget = nil; Task { await store.refresh(force: true) } }
    @objc func willSleep() { sleeping = true; store.suspended = true; store.captureQueue.removeAll(); hidePreview(); timer?.invalidate(); timer = nil }
    @objc func didWake() { sleeping = false; store.suspended = false; screensChanged(); Task { await store.refresh(force: true); await store.warmMissing() } }
    @objc func screensChanged() { cachedDockTarget = nil; updateDockOrientation(); hidePreview(); pointerChanged() }
    func updateDockOrientation() {
        dockOrientation = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom"
    }

    func pointerChanged() {
        guard !sleeping else { return }
        let point = NSEvent.mouseLocation
        if point != cachedDockPoint { dockProbeBudget.reset() }
        let nearAnyEdge = NSScreen.screens.contains { screen in
            ["bottom", "left", "right"].contains { nearDockEdge(point, screen: screen.frame, orientation: $0) }
        }
        if demo || previewVisible || hoveredPID != nil || nearAnyEdge {
            if timer == nil {
                let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
                t.tolerance = 0.003
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            timer?.invalidate(); timer = nil
        }
    }
    @objc func quitApp() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func dockTarget(at point: CGPoint) -> (pid_t, CGRect)? {
        if point == cachedDockPoint, let cachedDockTarget { return cachedDockTarget }
        if point == cachedDockPoint, Date().timeIntervalSince(lastDockLookup) < 0.12 { return nil }
        cachedDockPoint = point
        cachedDockTarget = nil
        lastDockLookup = Date()
        dockLookupCount += 1
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let flipped = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        var hit: AXUIElement?
        let dockAX = AXUIElementCreateApplication(dock.processIdentifier)
        guard AXUIElementCopyElementAtPosition(dockAX, Float(flipped.x), Float(flipped.y), &hit) == .success, var element = hit else { return nil }
        for _ in 0..<8 {
            let subrole: String = ax(element, kAXSubroleAttribute) ?? ""
            if subrole == "AXApplicationDockItem" {
                let title: String = ax(element, kAXTitleAttribute) ?? ""
                let url: URL? = ax(element, kAXURLAttribute)
                let candidates = NSWorkspace.shared.runningApplications.filter {
                    $0.processIdentifier != getpid() && ($0.bundleURL == url || (url == nil && $0.localizedName == title))
                }
                guard candidates.count == 1, let rect = axRect(element) else { return nil }
                let result = (candidates[0].processIdentifier, cocoaRect(rect))
                cachedDockTarget = result
                return result
            }
            guard let parent: AXUIElement = ax(element, kAXParentAttribute) else { break }
            element = parent
        }
        return nil
    }

    func poll() {
        pointerPollCount += 1
        let point = NSEvent.mouseLocation
        if demo {
            if Date() > demoExpires && !previewGroupContains(point, frames: previewFrames) { hidePreview() }
            return
        }
        if Date().timeIntervalSince(lastPermissionCheck) >= 1 {
            lastPermissionCheck = Date()
            if !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() {
                store.clearPrivateCache(); hidePreview(); timer?.invalidate(); timer = nil
                return
            }
        }
        if previewGroupContains(point, frames: previewFrames) { renderCurrent(); return }
        if previewFrames.contains(where: { isPreviewBridge(point, icon: dockRect, preview: $0) }) { renderCurrent(); return }
        if hoveredPID == nil { updateDockOrientation() }
        guard NSScreen.screens.contains(where: { nearDockEdge(point, screen: $0.frame, orientation: dockOrientation) }) else {
            if hoveredPID != nil { hidePreview() }
            timer?.invalidate(); timer = nil
            return
        }
        let target = dockTarget(at: point)
        if let (pid, rect) = target,
           isDockPreviewTrigger(point, icon: rect) || (previewVisible && hoveredPID == pid) {
            dockRect = rect
            if hoveredPID != pid {
                generation += 1
                hoveredPID = pid
                hoverBegan = Date()
                panels.forEach { $0.orderOut(nil) }
                renderedIDs = []
                lastRender = .distantPast
            }
            if Date().timeIntervalSince(hoverBegan) >= 0.08 { renderCurrent() }
            return
        }
        if hoveredPID != nil { hidePreview() }
        if !dockProbeBudget.retry(targetExists: target != nil, at: Date.timeIntervalSinceReferenceDate) {
            timer?.invalidate(); timer = nil
        }
    }

    func hidePreview() {
        generation += 1
        panels.forEach { $0.orderOut(nil) }
        hoveredPID = nil
        renderedIDs = []
        demo = false
        cachedDockTarget = nil
        cachedDockPoint = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    }

    func renderCurrent(force: Bool = false) {
        guard let pid = hoveredPID, !demo else { return }
        // Changing icons must show an existing cache even if the previous icon's capture is still pending.
        if !previewVisible || force { presentCached(pid: pid) }
        guard !rendering, force || Date().timeIntervalSince(lastRender) >= 0.7 else { return }
        rendering = true
        lastRender = Date()
        let token = generation
        // Draw the warm memory cache synchronously; fresh capture must not delay the first preview.
        presentCached(pid: pid)
        Task {
            await store.refresh()
            let windows = store.windows(for: pid)
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(dockRect) }) ?? NSScreen.main
            let actualWidth = screen.map {
                separatePreviewFrames(count: windows.count, width: previewWidth, visible: $0.visibleFrame.insetBy(dx: 8, dy: 8), anchor: dockRect, orientation: dockOrientation).first?.width ?? previewWidth
            } ?? previewWidth
            await store.capture(windows.map(\.id), width: max(1, actualWidth - 4))
            defer { rendering = false }
            guard generation == token, hoveredPID == pid else { return }
            presentCached(pid: pid)
        }
    }

    func presentCached(pid: pid_t) {
        let available = store.windows(for: pid).filter { store.images[$0.id] != nil }
        guard !available.isEmpty else { panels.forEach { $0.orderOut(nil) }; return }
        let ids = available.map(\.id)
        buildPreview(images: available.compactMap { store.images[$0.id] }, ids: ids, minimized: available.map(\.minimized), anchor: dockRect)
        renderedIDs = ids
    }

    func buildPreview(images: [NSImage], ids: [CGWindowID], minimized: [Bool], anchor: CGRect) {
        guard images.count == ids.count, minimized.count == images.count else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        let orientation = demo ? "bottom" : (CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom")
        let frames = separatePreviewFrames(count: images.count, width: previewWidth, visible: screen.visibleFrame.insetBy(dx: 8, dy: 8), anchor: anchor, orientation: orientation)
        while panels.count > images.count { panels.removeLast().orderOut(nil) }
        while panels.count < images.count { panels.append(PreviewPanel()) }
        for (index, image) in images.enumerated() {
            let panel = panels[index]
            let frame = frames[index]
            if renderedIDs == ids && panel.isVisible && !demo,
               panel.frame.size == frame.size,
               let glass = panel.contentView as? NSGlassEffectView,
               let view = glass.contentView as? ThumbnailView {
                view.image = image
                view.minimized = minimized[index]
                view.closeButtonSide = closeButtonSide
                view.needsDisplay = true
            } else {
                let glass = NSGlassEffectView(frame: CGRect(origin: .zero, size: frame.size))
                glass.style = .clear
                glass.cornerRadius = 14
                let view = ThumbnailView(frame: glass.bounds.insetBy(dx: 2, dy: 2))
                view.image = image
                view.minimized = minimized[index]
                view.closeButtonSide = closeButtonSide
                view.setAccessibilityElement(true)
                view.setAccessibilityRole(.button)
                view.setAccessibilityLabel("Открыть окно \(index + 1)")
                view.action = { [weak self] in
                    guard let self else { return }
                    if !self.demo, index < ids.count { self.store.focus(ids[index]) }
                    self.hidePreview()
                }
                let id = ids[index]
                view.closeAction = { [weak self] in
                    guard let self else { return }
                    if self.demo {
                        self.demoItems = removingPreview(id, from: self.demoItems)
                        if self.demoItems.isEmpty { self.hidePreview(); return }
                        self.buildDemoPreview()
                    } else if self.store.close(id) {
                        self.hidePreview()
                    } else {
                        NSSound.beep()
                    }
                }
                glass.contentView = view
                panel.contentView = glass
            }
            panel.setAccessibilityLabel("GlassDock — предпросмотр \(index + 1)")
            panel.alphaValue = previewOpacity
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
    }

    @objc func showDemo() {
        hidePreview()
        demo = true
        pointerChanged()
        demoExpires = Date().addingTimeInterval(18)
        demoItems = [PreviewItem(id: 101, content: demoImage(.systemBlue, alternate: false), minimized: false), PreviewItem(id: 102, content: demoImage(.systemPurple, alternate: true), minimized: true)]
        let screen = NSScreen.main ?? NSScreen.screens[0]
        demoAnchor = CGRect(x: screen.visibleFrame.midX - 25, y: screen.visibleFrame.minY, width: 50, height: 50)
        buildDemoPreview()
    }

    func buildDemoPreview() {
        buildPreview(images: demoItems.map(\.content), ids: demoItems.map(\.id), minimized: demoItems.map(\.minimized), anchor: demoAnchor)
    }

    func demoImage(_ color: NSColor, alternate: Bool) -> NSImage {
        let image = NSImage(size: CGSize(width: 720, height: 460))
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        CGRect(x: 0, y: 0, width: 720, height: 460).fill()
        color.withAlphaComponent(0.1).setFill()
        CGRect(x: 0, y: 0, width: 155, height: 460).fill()
        for n in 0..<6 {
            color.withAlphaComponent(n == 1 ? 0.35 : 0.12).setFill()
            NSBezierPath(roundedRect: CGRect(x: 18, y: 380 - n * 48, width: 120, height: 28), xRadius: 7, yRadius: 7).fill()
        }
        color.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: CGRect(x: 183, y: 300, width: 505, height: 110), xRadius: 16, yRadius: 16).fill()
        let text = alternate ? "Идеи на сегодня" : "Хороший день начинается здесь"
        (text as NSString).draw(at: CGPoint(x: 206, y: 345), withAttributes: [.font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.white])
        for n in 0..<3 {
            NSColor.secondaryLabelColor.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: CGRect(x: 183, y: 65 + n * 70, width: 505, height: 50), xRadius: 12, yRadius: 12).fill()
        }
        image.unlockFocus()
        return image
    }

    func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }

    func window(title: String, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    func settingsRow(_ title: String, value: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.addArrangedSubview(label(title))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(value)
        return row
    }

    func settingsCard(_ title: String, symbol: String, views: [NSView]) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 18
        glass.translatesAutoresizingMaskIntoConstraints = false
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 8
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        heading.addArrangedSubview(icon)
        heading.addArrangedSubview(label(title, size: 14, weight: .semibold))
        content.addArrangedSubview(heading)
        for view in views {
            content.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36).isActive = true
        }
        glass.contentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.topAnchor),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
        ])
        return glass
    }

    @objc func showSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = window(title: "GlassDock — настройки", width: 500, height: 660)
        w.styleMask.insert(.resizable)
        w.titlebarAppearsTransparent = true
        w.contentMinSize = NSSize(width: 420, height: 380)
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        w.contentView = background
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: background.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        let icon = NSImageView(image: NSImage(systemSymbolName: "rectangle.stack.fill", accessibilityDescription: "GlassDock")!)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        icon.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let titles = NSStackView()
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 4
        titles.addArrangedSubview(label("GlassDock", size: 24, weight: .semibold))
        let subtitle = label("Окна всегда под рукой", size: 12)
        subtitle.textColor = .secondaryLabelColor
        titles.addArrangedSubview(subtitle)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(titles)
        stack.addArrangedSubview(header)

        let sizeValue = label("\(Int(previewWidth)) pt", size: 12)
        sizeValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeValue.textColor = .secondaryLabelColor
        sizeLabel = sizeValue
        let size = NSSlider(value: previewWidth, minValue: 140, maxValue: 420, target: self, action: #selector(settingsChanged))
        size.isContinuous = true
        size.setAccessibilityLabel("Размер окон предпросмотра")
        sizeSlider = size
        let opacityValue = label("\(Int(previewOpacity * 100))%", size: 12)
        opacityValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        opacityValue.textColor = .secondaryLabelColor
        opacityLabel = opacityValue
        let opacity = NSSlider(value: previewOpacity, minValue: 0.35, maxValue: 1, target: self, action: #selector(settingsChanged))
        opacity.isContinuous = true
        opacity.setAccessibilityLabel("Непрозрачность окон предпросмотра")
        opacitySlider = opacity
        stack.addArrangedSubview(settingsCard("Предпросмотр", symbol: "rectangle.on.rectangle", views: [
            settingsRow("Размер миниатюр", value: sizeValue), size,
            settingsRow("Непрозрачность", value: opacityValue), opacity
        ]))

        let closeSide = NSSegmentedControl(labels: ["Слева", "Справа"], trackingMode: .selectOne, target: self, action: #selector(settingsChanged))
        closeSide.selectedSegment = closeButtonSide == "left" ? 0 : 1
        closeSide.setAccessibilityLabel("Угол крестика закрытия")
        closeSideControl = closeSide
        stack.addArrangedSubview(settingsCard("Управление окнами", symbol: "xmark.circle", views: [
            settingsRow("Кнопка закрытия", value: closeSide)
        ]))

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let updateButton = NSButton(title: "Обновить", target: self, action: #selector(updateApp))
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .large
        self.updateButton = updateButton
        let updateStatus = label(updater.status, size: 12)
        updateStatus.textColor = .secondaryLabelColor
        self.updateStatus = updateStatus
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        self.updateProgress = progress
        stack.addArrangedSubview(settingsCard("Обновления", symbol: "arrow.triangle.2.circlepath", views: [
            settingsRow("Версия \(version)", value: updateButton), updateStatus, progress
        ]))
        let hint = label("Последнее активное или свёрнутое окно — первым. Содержимое окон остаётся на этом Mac.", size: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        let glassContainer = SettingsGlassContainer()
        glassContainer.translatesAutoresizingMaskIntoConstraints = false
        glassContainer.contentView = stack
        scroll.documentView = glassContainer
        NSLayoutConstraint.activate([
            glassContainer.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            glassContainer.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            glassContainer.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            glassContainer.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: glassContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glassContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: glassContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glassContainer.bottomAnchor)
        ])
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        updateObservation = Publishers.CombineLatest3(updater.$status, updater.$busy, updater.$progress)
            .sink { [weak self] status, busy, progress in
                self?.refreshUpdate(status: status, busy: busy, progress: progress)
            }
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func refreshUpdate(status: String, busy: Bool, progress: Double?) {
        updateButton?.isEnabled = !busy
        updateStatus?.stringValue = status
        updateProgress?.isHidden = !busy
        updateProgress?.isIndeterminate = progress == nil
        if let progress { updateProgress?.doubleValue = progress }
        if busy { updateProgress?.startAnimation(nil) }
        else { updateProgress?.stopAnimation(nil) }
    }

    @objc func updateApp() {
        showSettings()
        updater.update()
    }

    @objc func settingsChanged() {
        guard let sizeSlider, let opacitySlider else { return }
        UserDefaults.standard.set(sizeSlider.doubleValue, forKey: "previewWidth")
        UserDefaults.standard.set(opacitySlider.doubleValue, forKey: "previewOpacity")
        store.thumbnailWidth = previewWidth
        if let closeSideControl {
            UserDefaults.standard.set(closeSideControl.selectedSegment == 0 ? "left" : "right", forKey: "closeButtonSide")
        }
        sizeLabel?.stringValue = "\(Int(previewWidth)) pt"
        opacityLabel?.stringValue = "\(Int(previewOpacity * 100))%"
        if demo { showDemo() }
        else if previewVisible { renderedIDs = []; renderCurrent(force: true) }
    }

    @objc func showPermissions() {
        if let permissionsWindow { permissionsWindow.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = window(title: "Добро пожаловать в GlassDock", width: 470, height: 380)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 25, left: 25, bottom: 25, right: 25)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label("Маленькие окна. Только содержимое.", size: 19, weight: .semibold))
        stack.addArrangedSubview(label("GlassDock нужен доступ к Универсальному доступу для значков Dock и переключения окон, а также к Записи экрана для миниатюр. Разрешите их вручную в настройках macOS. Снимки остаются только в памяти."))
        let accessibility = NSButton(title: "Открыть Универсальный доступ", target: self, action: #selector(openAccessibility))
        accessibility.bezelStyle = .rounded
        stack.addArrangedSubview(accessibility)
        let recording = NSButton(title: "Открыть Запись экрана", target: self, action: #selector(openRecording))
        recording.bezelStyle = .rounded
        stack.addArrangedSubview(recording)
        stack.addArrangedSubview(label("После выдачи доступов перезапустите GlassDock. Для проверки внешнего вида: значок в строке меню → Показать демо."))
        w.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor), stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor), stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor)])
        for view in stack.arrangedSubviews where view is NSTextField {
            view.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }
        permissionsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    @objc func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func openRecording() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

if AppUpdater.runHelperIfRequested(configuration: glassDockUpdateConfiguration) {
    // The update helper finishes before the normal application is created.
} else if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
} else if CommandLine.arguments.contains("--diagnostics") {
    print("GlassDock diagnostics")
    print("Accessibility: \(AXIsProcessTrusted())")
    print("Screen capture: \(CGPreflightScreenCaptureAccess())")
    print("Displays: \(NSScreen.screens.count)")
    for screen in NSScreen.screens { print("Display frame: \(screen.frame)") }
    let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    print("Window metadata count: \(windows.count)")
    print("No window titles or captured content emitted.")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
