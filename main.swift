import AppKit
import ApplicationServices
import ScreenCaptureKit

private func ax<T>(_ element: AXUIElement, _ name: String) -> T? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result as? T
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
    var records: [CGWindowID: WindowRecord] = [:]
    var images = ThumbnailCache<NSImage>(capacity: 96)
    var order = WindowOrder()
    var observers: [pid_t: AXObserver] = [:]
    var observedWindows: [pid_t: [AXUIElement]] = [:]
    var refreshing = false
    var captureBusy = false
    var onChange: (() -> Void)?

    func match(_ element: AXUIElement, pid: pid_t) -> CGWindowID? {
        let title: String = ax(element, kAXTitleAttribute) ?? ""
        let rect = axRect(element)
        let candidates = records.values.filter { $0.pid == pid }
        if let exact = candidates.first(where: { $0.element.map { CFEqual($0, element) } ?? false }) { return exact.id }
        if let rect {
            let geometric = candidates.filter {
                abs($0.window.frame.minX - rect.minX) < 3 && abs($0.window.frame.minY - rect.minY) < 3 &&
                abs($0.window.frame.width - rect.width) < 3 && abs($0.window.frame.height - rect.height) < 3
            }
            if let named = geometric.first(where: { $0.window.title == title }) { return named.id }
            if geometric.count == 1 { return geometric[0].id }
        }
        let named = candidates.filter { $0.window.title == title && !title.isEmpty }
        return named.count == 1 ? named[0].id : nil
    }

    func event(_ element: AXUIElement, notification: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if notification == kAXWindowMiniaturizedNotification || notification == kAXFocusedWindowChangedNotification {
            let target: AXUIElement = notification == kAXFocusedWindowChangedNotification
                ? (ax(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) ?? element) : element
            if let id = match(target, pid: pid) {
                if notification == kAXWindowMiniaturizedNotification {
                    order.minimize(id, pid: pid, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, time: Date.timeIntervalSinceReferenceDate)
                } else {
                    order.focus(id, pid: pid, time: Date.timeIntervalSinceReferenceDate)
                }
                onChange?()
            }
        }
        Task {
            await refresh()
            if notification == kAXFocusedWindowChangedNotification || notification == kAXWindowCreatedNotification {
                if let front = NSWorkspace.shared.frontmostApplication {
                    await capture(windows(for: front.processIdentifier).filter { !$0.minimized }.map(\.id), width: 420)
                }
            }
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

    func refresh() async {
        guard !refreshing, AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { return }
        refreshing = true
        defer { refreshing = false }
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
                    let sameFrame = candidates.filter {
                        abs($0.frame.minX - rect.minX) < 3 && abs($0.frame.minY - rect.minY) < 3 &&
                        abs($0.frame.width - rect.width) < 3 && abs($0.frame.height - rect.height) < 3
                    }
                    let sameTitle = candidates.filter { $0.title == title && !title.isEmpty }
                    let window = sameFrame.first(where: { $0.title == title }) ?? (sameFrame.count == 1 ? sameFrame[0] : nil) ?? (sameTitle.count == 1 ? sameTitle[0] : nil)
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
            records = next
            images.prune(live: Set(next.keys))
            order.prune(live: Set(next.keys))
            sampleFocus()
            onChange?()
        } catch {
            NSLog("GlassDock: window inventory unavailable: %@", error.localizedDescription)
        }
    }

    func sampleFocus() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let element: AXUIElement? = ax(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
        if let element, let id = match(element, pid: app.processIdentifier), id != order.lastFocused {
            order.focus(id, pid: app.processIdentifier, time: Date.timeIntervalSinceReferenceDate)
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
                onChange?()
                return
            }
            if let window: AXUIElement = ax(element, kAXWindowAttribute) { element = window }
            else if let parent: AXUIElement = ax(element, kAXParentAttribute) { element = parent }
            else { return }
        }
    }

    func capture(_ ids: [CGWindowID], width: CGFloat) async {
        guard !captureBusy, CGPreflightScreenCaptureAccess() else { return }
        captureBusy = true
        defer { captureBusy = false }
        for id in ids {
            guard let record = records[id], !record.minimized else { continue }
            let configuration = SCStreamConfiguration()
            let aspect = record.window.frame.height / max(1, record.window.frame.width)
            configuration.width = Int(width * 2)
            configuration.height = max(1, min(700, Int(width * 2 * aspect)))
            configuration.showsCursor = false
            configuration.scalesToFit = true
            configuration.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: record.window)
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                guard records[id] != nil else { continue }
                images[id] = NSImage(cgImage: image, size: .zero)
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

@MainActor private final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = WindowStore()
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
    var mouseMonitor: Any?
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
        let menu = NSMenu()
        for (title, selector) in [("Настройки…", #selector(showSettings)), ("Доступы macOS…", #selector(showPermissions)), ("Показать демо", #selector(showDemo))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
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
            self.renderCurrent(force: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        cacheTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    await self.store.refresh()
                    // Cache visible windows before they minimize. Memory only; no screenshot files.
                    let ids = self.store.order.sorted(self.store.records.values.filter { !$0.minimized && $0.window.isOnScreen }.map(\.id))
                    await self.store.capture(Array(ids.prefix(96)), width: self.previewWidth)
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeAppChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.explicitClick() }
        }
        if CommandLine.arguments.contains("--demo") { showDemo() }
        else if !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() { showPermissions() }
        else if !CommandLine.arguments.contains("--background") { showSettings() }
        Task { await store.refresh() }
    }

    @objc func activeAppChanged() { store.sampleFocus(); Task { await store.refresh() } }
    @objc func quitApp() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func dockTarget(at point: CGPoint) -> (pid_t, CGRect)? {
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
                return (candidates[0].processIdentifier, cocoaRect(rect))
            }
            guard let parent: AXUIElement = ax(element, kAXParentAttribute) else { break }
            element = parent
        }
        return nil
    }

    func poll() {
        let point = NSEvent.mouseLocation
        if demo {
            if Date() > demoExpires && !previewGroupContains(point, frames: previewFrames) { hidePreview() }
            return
        }
        store.sampleFocus()
        if previewGroupContains(point, frames: previewFrames) { return }
        if previewFrames.contains(where: { isPreviewBridge(point, icon: dockRect, preview: $0) }) { return }
        if let (pid, rect) = dockTarget(at: point),
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
    }

    func hidePreview() {
        generation += 1
        panels.forEach { $0.orderOut(nil) }
        hoveredPID = nil
        renderedIDs = []
        demo = false
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
            await store.capture(windows.map(\.id), width: previewWidth)
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

    @objc func showSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = window(title: "GlassDock", width: 420, height: 440)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 25, left: 25, bottom: 25, right: 25)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label("Предпросмотр окон", size: 20, weight: .semibold))
        sizeLabel = label("Размер: \(Int(previewWidth)) pt")
        stack.addArrangedSubview(sizeLabel!)
        let size = NSSlider(value: previewWidth, minValue: 140, maxValue: 420, target: self, action: #selector(settingsChanged))
        size.isContinuous = true
        size.setAccessibilityLabel("Размер окон предпросмотра")
        sizeSlider = size
        stack.addArrangedSubview(size)
        opacityLabel = label("Непрозрачность: \(Int(previewOpacity * 100))%")
        stack.addArrangedSubview(opacityLabel!)
        let opacity = NSSlider(value: previewOpacity, minValue: 0.35, maxValue: 1, target: self, action: #selector(settingsChanged))
        opacity.isContinuous = true
        opacity.setAccessibilityLabel("Непрозрачность окон предпросмотра")
        opacitySlider = opacity
        stack.addArrangedSubview(opacity)
        stack.addArrangedSubview(label("Крестик закрытия"))
        let closeSide = NSSegmentedControl(labels: ["Слева", "Справа"], trackingMode: .selectOne, target: self, action: #selector(settingsChanged))
        closeSide.selectedSegment = closeButtonSide == "left" ? 0 : 1
        closeSide.setAccessibilityLabel("Угол крестика закрытия")
        closeSideControl = closeSide
        stack.addArrangedSubview(closeSide)
        let hint = label("Последнее открытое или свёрнутое окно всегда первым. Содержимое свёрнутых окон появляется после первого открытия; кеш хранит до 96 окон только в памяти.")
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        w.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor), stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor), stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor)])
        size.widthAnchor.constraint(equalToConstant: 370).isActive = true
        opacity.widthAnchor.constraint(equalToConstant: 370).isActive = true
        for view in stack.arrangedSubviews where view is NSTextField {
            view.widthAnchor.constraint(equalToConstant: 370).isActive = true
        }
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func settingsChanged() {
        guard let sizeSlider, let opacitySlider else { return }
        UserDefaults.standard.set(sizeSlider.doubleValue, forKey: "previewWidth")
        UserDefaults.standard.set(opacitySlider.doubleValue, forKey: "previewOpacity")
        if let closeSideControl {
            UserDefaults.standard.set(closeSideControl.selectedSegment == 0 ? "left" : "right", forKey: "closeButtonSide")
        }
        sizeLabel?.stringValue = "Размер: \(Int(previewWidth)) pt"
        opacityLabel?.stringValue = "Непрозрачность: \(Int(previewOpacity * 100))%"
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

if CommandLine.arguments.contains("--self-test") {
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
