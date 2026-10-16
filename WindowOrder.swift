import Foundation

func matchingWindow<Value>(in candidates: [Value], nativeID: UInt32?, frame: CGRect?, title: String,
                           id: (Value) -> UInt32, geometry: (Value) -> CGRect, name: (Value) -> String?) -> Value? {
    if let nativeID { return candidates.first(where: { id($0) == nativeID }) }
    if let frame {
        let geometric = candidates.filter {
            let candidate = geometry($0)
            return abs(candidate.minX - frame.minX) < 3 && abs(candidate.minY - frame.minY) < 3 &&
                abs(candidate.width - frame.width) < 3 && abs(candidate.height - frame.height) < 3
        }
        let named = geometric.filter { name($0) == title }
        if named.count > 1 { return nil }
        if named.count == 1 { return named[0] }
        if geometric.count == 1 { return geometric[0] }
    }
    let named = candidates.filter { name($0) == title && !title.isEmpty }
    return named.count == 1 ? named[0] : nil
}

func separatePreviewFrames(count: Int, width: CGFloat, visible: CGRect, anchor: CGRect, orientation: String) -> [CGRect] {
    guard count > 0 else { return [] }
    let gap: CGFloat = 6
    var itemWidth = min(width + 4, visible.width)
    var columns = 1, rows = count
    while true {
        columns = min(count, max(1, Int((visible.width + gap) / (itemWidth + gap))))
        rows = Int(ceil(Double(count) / Double(columns)))
        let height = CGFloat(rows) * (itemWidth * 0.64 + gap) - gap
        if height <= visible.height * 0.65 || itemWidth <= 1 { break }
        itemWidth *= 0.9
    }
    let itemHeight = itemWidth * 0.64
    let groupWidth = CGFloat(columns) * (itemWidth + gap) - gap
    let groupHeight = CGFloat(rows) * (itemHeight + gap) - gap
    var x = anchor.midX - groupWidth / 2, y = anchor.maxY
    if orientation == "left" { x = anchor.maxX; y = anchor.midY - groupHeight / 2 }
    else if orientation == "right" { x = anchor.minX - groupWidth; y = anchor.midY - groupHeight / 2 }
    x = max(visible.minX, min(x, visible.maxX - groupWidth))
    y = max(visible.minY, min(y, visible.maxY - groupHeight))
    return (0..<count).map { index in
        CGRect(x: x + CGFloat(index % columns) * (itemWidth + gap), y: y + groupHeight - itemHeight - CGFloat(index / columns) * (itemHeight + gap), width: itemWidth, height: itemHeight)
    }
}

func previewGroupContains(_ point: CGPoint, frames: [CGRect]) -> Bool {
    if frames.contains(where: { $0.contains(point) }) { return true }
    for (index, frame) in frames.enumerated() {
        for other in frames.dropFirst(index + 1) {
            let horizontal = abs(frame.minY - other.minY) < 1 && min(abs(frame.maxX - other.minX), abs(other.maxX - frame.minX)) <= 6
            let vertical = abs(frame.minX - other.minX) < 1 && min(abs(frame.maxY - other.minY), abs(other.maxY - frame.minY)) <= 6
            if (horizontal || vertical) && (isPreviewBridge(point, icon: frame, preview: other) || isPreviewBridge(point, icon: other, preview: frame)) { return true }
        }
    }
    return false
}

func normalizedEnlargedPreviewAmount(_ value: Double) -> CGFloat {
    value.isFinite ? CGFloat(max(0, min(1, value))) : 0.1
}

func previewScreenIndex(thumbnail: CGRect, displays: [CGRect]) -> Int? {
    let center = CGPoint(x: thumbnail.midX, y: thumbnail.midY)
    if let index = displays.firstIndex(where: { $0.contains(center) }) { return index }
    return displays.indices.max { left, right in
        let a = displays[left].intersection(thumbnail), b = displays[right].intersection(thumbnail)
        return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
    }
}

func enlargedPreviewFrame(display: CGRect, visible: CGRect, thumbnail: CGRect, amount: CGFloat) -> CGRect {
    let fraction = normalizedEnlargedPreviewAmount(Double(amount))
    if fraction == 0 { return thumbnail }
    if fraction == 1 { return display }
    let target = visible.insetBy(dx: 8, dy: 8)
    let width = min(target.width, thumbnail.width + (target.width - thumbnail.width) * fraction)
    let height = min(target.height, thumbnail.height + (target.height - thumbnail.height) * fraction)
    return CGRect(x: max(target.minX, min(thumbnail.midX - width / 2, target.maxX - width)),
                  y: max(target.minY, min(thumbnail.midY - height / 2, target.maxY - height)), width: width, height: height)
}

func enlargedPreviewContains(_ point: CGPoint, thumbnails: [CGRect], enlarged: CGRect) -> Bool {
    if enlarged.contains(point) || previewGroupContains(point, frames: thumbnails) { return true }
    return thumbnails.contains { frame in
        let horizontalGap = max(frame.minX, enlarged.minX) - min(frame.maxX, enlarged.maxX)
        let verticalGap = max(frame.minY, enlarged.minY) - min(frame.maxY, enlarged.maxY)
        guard (horizontalGap >= 0 && horizontalGap <= 6.01) || (verticalGap >= 0 && verticalGap <= 6.01) else { return false }
        return isPreviewBridge(point, icon: frame, preview: enlarged) || isPreviewBridge(point, icon: enlarged, preview: frame)
    }
}

func thumbnailControlFrames(in bounds: CGRect, closeSide: String, magnifierSide: String = "left") -> (magnifier: CGRect, close: CGRect) {
    let close = previewCloseButtonFrame(in: bounds, side: closeSide)
    var magnifier = previewCloseButtonFrame(in: bounds, side: magnifierSide)
    if magnifier.intersects(close) {
        magnifier.origin.x = magnifierSide == "right" ? close.minX - 4 - magnifier.width : close.maxX + 4
    }
    if !bounds.contains(magnifier) || magnifier.intersects(close) {
        magnifier = CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
    }
    return (magnifier, close)
}

/// One native capture at a time; a changed/hidden selection invalidates its result.
struct EnlargedPreviewSession {
    private(set) var windowID: UInt32?
    private(set) var generation: UInt64 = 0
    private(set) var capturePending = false
    private(set) var nextCaptureAt: TimeInterval = 0
    private var failures = 0
    mutating func show(_ id: UInt32) { generation &+= 1; windowID = id; nextCaptureAt = 0; failures = 0 }
    mutating func hide() { generation &+= 1; windowID = nil; nextCaptureAt = 0; failures = 0 }
    mutating func beginCapture(now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> (id: UInt32, generation: UInt64)? {
        guard let windowID, !capturePending, now >= nextCaptureAt else { return nil }
        capturePending = true
        return (windowID, generation)
    }
    mutating func finishCapture(id: UInt32, generation: UInt64, success: Bool = true,
                                now: TimeInterval = Date.timeIntervalSinceReferenceDate, interval: TimeInterval = 2) -> Bool {
        capturePending = false
        guard windowID == id && self.generation == generation else { return false }
        failures = success ? 0 : min(failures + 1, 4)
        nextCaptureAt = now + min(30, interval * pow(2, Double(failures)))
        return true
    }
}

func enlargedPreviewRefreshInterval(lowPower: Bool, thermalSerious: Bool) -> TimeInterval {
    lowPower || thermalSerious ? 4 : 2
}

func isDockPreviewTrigger(_ point: CGPoint, icon: CGRect) -> Bool {
    icon.contains(point) && point.y <= icon.midY
}

struct PreviewItem<Value> {
    let id: UInt32
    let content: Value
    let minimized: Bool
}

func removingPreview<Value>(_ id: UInt32, from items: [PreviewItem<Value>]) -> [PreviewItem<Value>] {
    items.filter { $0.id != id }
}

func previewCloseButtonFrame(in bounds: CGRect, side: String) -> CGRect {
    let width = min(20, max(0, bounds.width - 4))
    let height = min(20, max(0, bounds.height - 4))
    let horizontalInset = min(6, max(0, (bounds.width - width) / 2))
    let verticalInset = min(6, max(0, (bounds.height - height) / 2))
    let x = side == "left" ? bounds.minX + horizontalInset : bounds.maxX - horizontalInset - width
    return CGRect(x: x, y: bounds.maxY - verticalInset - height, width: width, height: height)
}

func isPreviewBridge(_ point: CGPoint, icon: CGRect, preview: CGRect) -> Bool {
    if preview.minY >= icon.maxY {
        let left = max(icon.minX, preview.minX), right = min(icon.maxX, preview.maxX)
        return right > left && CGRect(x: left, y: icon.maxY, width: right - left, height: preview.minY - icon.maxY).contains(point)
    }
    let bottom = max(icon.minY, preview.minY), top = min(icon.maxY, preview.maxY)
    guard top > bottom else { return false }
    if preview.minX >= icon.maxX {
        return CGRect(x: icon.maxX, y: bottom, width: preview.minX - icon.maxX, height: top - bottom).contains(point)
    }
    if icon.minX >= preview.maxX {
        return CGRect(x: preview.maxX, y: bottom, width: icon.minX - preview.maxX, height: top - bottom).contains(point)
    }
    return false
}

/// A monotonic event order: minimizing and focusing have equal recency priority.
struct WindowOrder {
    private(set) var clock: UInt64 = 0
    private(set) var recency: [UInt32: UInt64] = [:]
    private(set) var lastFocused: UInt32?
    private var fallbackPID: Int32?
    private var fallbackUntil: TimeInterval = 0
    mutating func touch(_ id: UInt32) {
        clock += 1
        recency[id] = clock
    }
    mutating func prune(live: Set<UInt32>) {
        recency = recency.filter { live.contains($0.key) }
        if let lastFocused, !live.contains(lastFocused) { self.lastFocused = nil }
    }
    mutating func focus(_ id: UInt32, pid: Int32, time: TimeInterval) {
        lastFocused = id
        if fallbackPID == pid && time < fallbackUntil { return }
        fallbackPID = nil
        touch(id)
    }
    mutating func minimize(_ id: UInt32, pid: Int32, frontmostPID: Int32?, time: TimeInterval) {
        if lastFocused == id && frontmostPID == pid {
            fallbackPID = pid
            fallbackUntil = time + 0.35
        }
        touch(id)
    }
    mutating func explicitInput(clickedWindow: UInt32? = nil) {
        fallbackPID = nil
        if let clickedWindow, clickedWindow == lastFocused { touch(clickedWindow) }
    }
    func sorted(_ ids: [UInt32]) -> [UInt32] {
        ids.sorted {
            let left = recency[$0, default: 0], right = recency[$1, default: 0]
            return left == right ? $0 < $1 : left > right
        }
    }
}

/// Bounded in-memory cache. A failed/minimized capture leaves its last good image intact.
struct ThumbnailCache<Value> {
    let capacity: Int
    let byteLimit: Int
    init(capacity: Int, byteLimit: Int = .max) { self.capacity = max(1, capacity); self.byteLimit = max(1, byteLimit) }
    private var values: [UInt32: Value] = [:]
    private var costs: [UInt32: Int] = [:]
    private var priorities: [UInt32: UInt64] = [:]
    private var serial: UInt64 = 0
    private var usage: [UInt32] = []
    var count: Int { values.count }
    var byteCount: Int { costs.values.reduce(0, +) }
    mutating func prioritize(_ id: UInt32, value: UInt64) { if values[id] != nil { priorities[id] = value } }
    mutating func insert(_ value: Value, for id: UInt32, bytes: Int, priority: UInt64? = nil) {
        guard bytes <= byteLimit else { return }
        values.removeValue(forKey: id); costs.removeValue(forKey: id); usage.removeAll { $0 == id }
        priorities.removeValue(forKey: id)
        values[id] = value
        costs[id] = max(0, bytes)
        serial += 1
        priorities[id] = priority ?? serial
        usage.append(id)
        while usage.count > capacity || byteCount > byteLimit {
            let removed = usage.min { priorities[$0, default: 0] < priorities[$1, default: 0] }!
            usage.removeAll { $0 == removed }
            values.removeValue(forKey: removed); costs.removeValue(forKey: removed)
            priorities.removeValue(forKey: removed)
        }
    }
    mutating func removeAll() { values.removeAll(); costs.removeAll(); priorities.removeAll(); usage.removeAll() }
    subscript(_ id: UInt32) -> Value? {
        get { values[id] }
        set {
            guard let newValue else { values.removeValue(forKey: id); costs.removeValue(forKey: id); priorities.removeValue(forKey: id); usage.removeAll { $0 == id }; return }
            insert(newValue, for: id, bytes: 1)
        }
    }
    mutating func prune(live: Set<UInt32>) {
        values = values.filter { live.contains($0.key) }
        costs = costs.filter { live.contains($0.key) }
        priorities = priorities.filter { live.contains($0.key) }
        usage.removeAll { !live.contains($0) }
    }
}

struct WorkThrottle {
    private var last: [UInt32: TimeInterval] = [:]
    mutating func allow(_ id: UInt32, at time: TimeInterval, interval: TimeInterval) -> Bool {
        if let previous = last[id], time - previous < interval { return false }
        last[id] = time
        return true
    }
    mutating func prune(live: Set<UInt32>) { last = last.filter { live.contains($0.key) } }
}

struct DockProbeBudget {
    private var began: TimeInterval?
    mutating func reset() { began = nil }
    mutating func retry(targetExists: Bool, at time: TimeInterval) -> Bool {
        guard !targetExists else { return false }
        if began == nil { began = time }
        return time - began! < 1.5
    }
}

func nearDockEdge(_ point: CGPoint, screen: CGRect, orientation: String) -> Bool {
    guard screen.contains(point) else { return false }
    if orientation == "left" { return point.x <= screen.minX + 180 }
    if orientation == "right" { return point.x >= screen.maxX - 180 }
    return point.y <= screen.minY + 180
}

func shouldRefreshForegroundThumbnail(suspended: Bool, busy: Bool, minimized: Bool, owner: Int32, frontmost: Int32?, hidden: Bool) -> Bool {
    !suspended && !busy && !minimized && owner == frontmost && !hidden
}

func runSelfTests() {
    struct MatchFixture { let id: UInt32; let frame: CGRect; let title: String }
    let matchingFrame = CGRect(x: 10, y: 20, width: 500, height: 400)
    let duplicates = [MatchFixture(id: 1, frame: matchingFrame, title: "Untitled"), MatchFixture(id: 2, frame: matchingFrame, title: "Untitled")]
    func matched(_ fixtures: [MatchFixture], nativeID: UInt32? = nil, frame: CGRect? = matchingFrame, title: String = "Untitled") -> UInt32? {
        matchingWindow(in: fixtures, nativeID: nativeID, frame: frame, title: title, id: { $0.id }, geometry: { $0.frame }, name: { $0.title })?.id
    }
    precondition(matched(duplicates) == nil, "Ambiguous title and frame must not select another window")
    precondition(matched(duplicates, nativeID: 2) == 2)
    precondition(matched(duplicates, nativeID: 99) == nil)
    precondition(matched([duplicates[0]], nativeID: 99) == nil, "A known absent ID must never fall back to a lookalike")
    precondition(matched([duplicates[0]], nativeID: 2) == nil, "An ID outside the PID-filtered candidates must not bind another window")
    precondition(matched([duplicates[0]]) == 1)
    precondition(matched([duplicates[0]], title: "Changed title") == 1)
    precondition(matched([duplicates[0]], frame: nil) == 1)
    precondition(matched([duplicates[0], MatchFixture(id: 2, frame: matchingFrame, title: "Other")], title: "Other") == 2)
    precondition(matched(duplicates, frame: nil) == nil)
    var order = WindowOrder()
    order.touch(11) // focus
    order.touch(22) // minimize
    precondition(order.sorted([11, 22, 33]) == [22, 11, 33])
    order.touch(11) // focus after minimize
    precondition(order.sorted([22, 11]) == [11, 22])
    order.prune(live: [22, 33])
    precondition(order.recency[11] == nil)
    precondition(order.sorted([33, 22]) == [22, 33])
    precondition(order.sorted([]).isEmpty)
    precondition(order.sorted([8, 2]) == [2, 8])
    var cache = ThumbnailCache<String>(capacity: 2)
    cache[11] = "visible content"
    order.touch(11) // minimize; no new capture available
    precondition(cache[11] == "visible content")
    cache[22] = "second"
    cache[33] = "third"
    precondition(cache.count == 2 && cache[11] == nil && cache[22] != nil)
    cache.prune(live: [33])
    precondition(cache.count == 1 && cache[22] == nil && cache[33] == "third")
    cache[33] = "updated"
    precondition(cache[33] == "updated")
    var policy = WindowOrder()
    policy.focus(1, pid: 10, time: 1)
    policy.minimize(1, pid: 10, frontmostPID: 10, time: 2)
    policy.focus(2, pid: 10, time: 2.02) // automatic sibling focus
    precondition(policy.sorted([1, 2]) == [1, 2] && policy.lastFocused == 2)
    policy.focus(2, pid: 10, time: 3) // later explicit focus
    precondition(policy.sorted([1, 2]) == [2, 1])
    policy.minimize(2, pid: 10, frontmostPID: 10, time: 4)
    policy.explicitInput()
    policy.focus(1, pid: 10, time: 4.01)
    precondition(policy.sorted([1, 2]) == [1, 2])
    policy.minimize(1, pid: 10, frontmostPID: 10, time: 5)
    policy.focus(2, pid: 10, time: 5.02)
    policy.explicitInput(clickedWindow: 2)
    precondition(policy.sorted([1, 2]) == [2, 1])
    let icon = CGRect(x: -200, y: 956, width: 60, height: 60)
    precondition(isDockPreviewTrigger(CGPoint(x: -170, y: 960), icon: icon))
    precondition(isDockPreviewTrigger(CGPoint(x: -170, y: 986), icon: icon))
    precondition(!isDockPreviewTrigger(CGPoint(x: -170, y: 986.01), icon: icon))
    precondition(!isDockPreviewTrigger(CGPoint(x: -170, y: 1010), icon: icon))
    precondition(!isDockPreviewTrigger(CGPoint(x: -201, y: 960), icon: icon))
    precondition(!isDockPreviewTrigger(CGPoint(x: -170, y: 955), icon: icon))
    let preview = CGRect(x: -240, y: 1020, width: 160, height: 100)
    precondition(isPreviewBridge(CGPoint(x: -170, y: 1018), icon: icon, preview: preview))
    precondition(!isPreviewBridge(CGPoint(x: -205, y: 1018), icon: icon, preview: preview))
    precondition(!isPreviewBridge(CGPoint(x: -170, y: 1121), icon: icon, preview: preview))
    precondition(!isPreviewBridge(CGPoint(x: -170, y: 955), icon: icon, preview: preview))
    let visible = CGRect(x: -300, y: 0, width: 1200, height: 800)
    let frames = separatePreviewFrames(count: 2, width: 230, visible: visible, anchor: icon, orientation: "bottom")
    precondition(frames.count == 2 && !frames[0].intersects(frames[1]) && frames[0].minX < frames[1].minX)
    precondition(frames.allSatisfy { visible.contains($0) })
    let between = CGPoint(x: (frames[0].maxX + frames[1].minX) / 2, y: frames[0].midY)
    precondition(previewGroupContains(between, frames: frames))
    precondition(!previewGroupContains(CGPoint(x: frames[0].minX - 1, y: frames[0].midY), frames: frames))
    precondition(separatePreviewFrames(count: 0, width: 230, visible: visible, anchor: icon, orientation: "bottom").isEmpty)
    let many = separatePreviewFrames(count: 96, width: 420, visible: visible, anchor: icon, orientation: "left")
    precondition(many.count == 96 && many.allSatisfy { visible.contains($0) })
    let fixtures = [PreviewItem(id: 101, content: "normal", minimized: false), PreviewItem(id: 102, content: "minimized", minimized: true)]
    let firstClosed = removingPreview(101, from: fixtures)
    precondition(firstClosed.count == 1 && firstClosed[0].id == 102 && firstClosed[0].minimized)
    let secondClosed = removingPreview(102, from: fixtures)
    precondition(secondClosed.count == 1 && secondClosed[0].id == 101 && !secondClosed[0].minimized)
    precondition(removingPreview(999, from: fixtures).count == 2)
    precondition(removingPreview(102, from: firstClosed).isEmpty)
    let card = CGRect(x: 0, y: 0, width: 230, height: 147)
    let leftClose = previewCloseButtonFrame(in: card, side: "left")
    let rightClose = previewCloseButtonFrame(in: card, side: "right")
    precondition(card.contains(leftClose) && card.contains(rightClose))
    precondition(leftClose.minX == 6 && rightClose.maxX == card.maxX - 6 && leftClose.maxY == rightClose.maxY)
    precondition(previewCloseButtonFrame(in: card, side: "invalid") == rightClose)
    let tinyCard = CGRect(x: 0, y: 0, width: 12, height: 8)
    precondition(tinyCard.contains(previewCloseButtonFrame(in: tinyCard, side: "right")))
    var bytes = ThumbnailCache<String>(capacity: 96, byteLimit: 10)
    bytes.insert("A", for: 1, bytes: 6); bytes.insert("B", for: 2, bytes: 6)
    precondition(bytes[1] == nil && bytes[2] == "B" && bytes.byteCount == 6)
    bytes.insert("large", for: 3, bytes: 11)
    precondition(bytes[3] == nil && bytes.byteCount == 6)
    bytes.insert("updated", for: 2, bytes: 3)
    precondition(bytes.byteCount == 3 && bytes.count == 1)
    bytes.prune(live: []); precondition(bytes.byteCount == 0)
    var throttle = WorkThrottle()
    precondition(throttle.allow(1, at: 0, interval: 0.7))
    precondition(!throttle.allow(1, at: 0.1, interval: 0.7))
    precondition(throttle.allow(2, at: 0.1, interval: 0.7))
    precondition(throttle.allow(1, at: 0.7, interval: 0.7))
    throttle.prune(live: []); precondition(throttle.allow(1, at: 0.71, interval: 0.7))
    precondition(nearDockEdge(CGPoint(x: -250, y: 400), screen: visible, orientation: "left"))
    precondition(!nearDockEdge(CGPoint(x: 300, y: 400), screen: visible, orientation: "bottom"))
    precondition(nearDockEdge(CGPoint(x: 850, y: 400), screen: visible, orientation: "right"))
    precondition(!nearDockEdge(CGPoint(x: -301, y: 0), screen: visible, orientation: "left"))
    var protected = ThumbnailCache<String>(capacity: 96, byteLimit: 10)
    protected.insert("recent minimized", for: 1, bytes: 6, priority: 10)
    protected.insert("old warm", for: 2, bytes: 6, priority: 0)
    precondition(protected[1] == "recent minimized" && protected[2] == nil)
    protected.prioritize(1, value: 20)
    protected.insert("less recent", for: 3, bytes: 6, priority: 11)
    precondition(protected[1] != nil && protected[3] == nil && protected.byteCount <= 10)
    protected.insert("oversized replacement", for: 1, bytes: 11)
    precondition(protected[1] == "recent minimized")
    precondition(shouldRefreshForegroundThumbnail(suspended: false, busy: false, minimized: false, owner: 1, frontmost: 1, hidden: false))
    precondition(!shouldRefreshForegroundThumbnail(suspended: true, busy: false, minimized: false, owner: 1, frontmost: 1, hidden: false))
    precondition(!shouldRefreshForegroundThumbnail(suspended: false, busy: true, minimized: false, owner: 1, frontmost: 1, hidden: false))
    precondition(!shouldRefreshForegroundThumbnail(suspended: false, busy: false, minimized: true, owner: 1, frontmost: 1, hidden: false))
    precondition(!shouldRefreshForegroundThumbnail(suspended: false, busy: false, minimized: false, owner: 1, frontmost: 2, hidden: false))
    precondition(!shouldRefreshForegroundThumbnail(suspended: false, busy: false, minimized: false, owner: 1, frontmost: nil, hidden: false))
    precondition(!shouldRefreshForegroundThumbnail(suspended: false, busy: false, minimized: false, owner: 1, frontmost: 1, hidden: true))
    var probe = DockProbeBudget()
    precondition(probe.retry(targetExists: false, at: 0))
    precondition(probe.retry(targetExists: false, at: 0.3))
    precondition(!probe.retry(targetExists: false, at: 1.5))
    precondition(!probe.retry(targetExists: true, at: 1.6))
    probe.reset()
    precondition(probe.retry(targetExists: false, at: 2))
    for closeSide in ["left", "right"] {
        for magnifierSide in ["left", "right"] {
            let controls = thumbnailControlFrames(in: card, closeSide: closeSide, magnifierSide: magnifierSide)
            precondition(controls.close == previewCloseButtonFrame(in: card, side: closeSide), "X remains at its configured outer edge")
            precondition(card.contains(controls.close) && card.contains(controls.magnifier))
            precondition(!controls.close.intersects(controls.magnifier), "Buttons must never overlap")
            precondition(magnifierSide == "left" ? controls.magnifier.midX < card.midX : controls.magnifier.midX > card.midX)
        }
    }
    let tinyControls = thumbnailControlFrames(in: tinyCard, closeSide: "left", magnifierSide: "left")
    precondition(tinyControls.close == previewCloseButtonFrame(in: tinyCard, side: "left") && tinyControls.magnifier.isEmpty)
    precondition(normalizedEnlargedPreviewAmount(.nan) == 0.1 && normalizedEnlargedPreviewAmount(.infinity) == 0.1)
    precondition(normalizedEnlargedPreviewAmount(-1) == 0 && normalizedEnlargedPreviewAmount(2) == 1)
    let displays = [CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: -1055, y: 956, width: 3440, height: 1440)]
    let externalMini = CGRect(x: -800, y: 980, width: 234, height: 150)
    precondition(previewScreenIndex(thumbnail: externalMini, displays: displays) == 1)
    for display in displays {
        let visible = display.insetBy(dx: 0, dy: 30)
        let row = separatePreviewFrames(count: 8, width: 230, visible: visible.insetBy(dx: 8, dy: 8), anchor: CGRect(x: visible.minX, y: visible.maxY - 100, width: 50, height: 50), orientation: "left")
        for mini in row {
            precondition(enlargedPreviewFrame(display: display, visible: visible, thumbnail: mini, amount: 0) == mini)
            precondition(enlargedPreviewFrame(display: display, visible: visible, thumbnail: mini, amount: 1) == display)
            for fraction: CGFloat in [0.01, 0.1, 0.5, 0.99] {
                let large = enlargedPreviewFrame(display: display, visible: visible, thumbnail: mini, amount: fraction)
                precondition(visible.insetBy(dx: 8, dy: 8).contains(large))
                precondition(large.intersects(mini), "Every size must connect to the clicked miniature, including ragged rows")
                precondition(enlargedPreviewContains(CGPoint(x: mini.midX, y: mini.midY), thumbnails: row, enlarged: large))
                precondition(!enlargedPreviewContains(CGPoint(x: display.maxX + 10, y: display.maxY + 10), thumbnails: row, enlarged: large))
            }
        }
    }
    let isolatedMinis = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 106, y: 0, width: 100, height: 100)]
    precondition(!enlargedPreviewContains(CGPoint(x: 180, y: 150), thumbnails: isolatedMinis, enlarged: CGRect(x: 0, y: 100, width: 100, height: 100)), "Empty bounding-box space must dismiss immediately")
    var enlarged = EnlargedPreviewSession()
    precondition(enlarged.beginCapture() == nil, "Hidden previews cannot start a capture")
    enlarged.show(1)
    let firstLargeCapture = enlarged.beginCapture()!
    precondition(enlarged.beginCapture() == nil, "Only one large capture may be in flight")
    enlarged.show(2)
    precondition(enlarged.beginCapture() == nil, "Repeated clicks coalesce behind the current capture")
    precondition(!enlarged.finishCapture(id: firstLargeCapture.id, generation: firstLargeCapture.generation))
    let nextLargeCapture = enlarged.beginCapture()!
    precondition(nextLargeCapture.id == 2)
    enlarged.hide()
    precondition(!enlarged.finishCapture(id: nextLargeCapture.id, generation: nextLargeCapture.generation), "Capture completion must not reopen a hidden panel")
    precondition(enlarged.beginCapture() == nil)
    enlarged.show(3)
    let finalLargeCapture = enlarged.beginCapture()!
    precondition(enlarged.finishCapture(id: finalLargeCapture.id, generation: finalLargeCapture.generation))
    var refresh = EnlargedPreviewSession()
    refresh.show(4)
    let initial = refresh.beginCapture(now: 10)!
    precondition(refresh.finishCapture(id: initial.id, generation: initial.generation, now: 10))
    precondition(refresh.beginCapture(now: 11.99) == nil)
    let failed = refresh.beginCapture(now: 12)!
    precondition(refresh.finishCapture(id: failed.id, generation: failed.generation, success: false, now: 12))
    precondition(refresh.nextCaptureAt == 16 && refresh.beginCapture(now: 15.99) == nil)
    let secondFailure = refresh.beginCapture(now: 16)!
    precondition(refresh.finishCapture(id: secondFailure.id, generation: secondFailure.generation, success: false, now: 16))
    precondition(refresh.nextCaptureAt == 24)
    let recovered = refresh.beginCapture(now: 24)!
    precondition(refresh.finishCapture(id: recovered.id, generation: recovered.generation, now: 24, interval: 4))
    precondition(refresh.nextCaptureAt == 28)
    precondition(enlargedPreviewRefreshInterval(lowPower: false, thermalSerious: false) == 2)
    precondition(enlargedPreviewRefreshInterval(lowPower: true, thermalSerious: false) == 4)
    precondition(enlargedPreviewRefreshInterval(lowPower: false, thermalSerious: true) == 4)
    refresh.hide()
    precondition(refresh.beginCapture(now: 1000) == nil)
    print("PASS: 74 existing checks + native-ID safety, magnifier geometry, refresh cadence/backoff and stale-capture lifecycle regressions")
}
