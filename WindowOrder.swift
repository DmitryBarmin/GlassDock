import Foundation

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
    print("PASS: 66 checks — preview/MRU/close regressions, byte-bound priority cache, capture throttle, bounded idle Dock probes and focused-only refresh lifecycle")
}
