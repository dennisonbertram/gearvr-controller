// Finds clickable UI elements (buttons, links, checkboxes, menu items, Dock icons…)
// near the pointer using the Accessibility API, for the magnetic pointer assist.
//
// Runs on a background queue ~12 times a second while active (AppModel stops it while the
// air-mouse is off or the controller is idle). It looks up the element under the pointer,
// takes its window (or menu bar / Dock list), then walks only the part of that subtree that
// intersects a box around the pointer, nearest-first, under a time budget.
import AppKit
import ApplicationServices

final class TargetScanner {
    /// Called on the main queue with target frames in global display coordinates.
    var onTargets: (([CGRect]) -> Void)?
    var searchRadius: CGFloat = 220

    // timer, lastScan and the app sets are only touched on `queue`
    private let queue = DispatchQueue(label: "gearvr.target-scanner", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let systemWide = AXUIElementCreateSystemWide()
    private var lastScan: (point: CGPoint, time: TimeInterval)?
    private var tunedApps: Set<pid_t> = []
    private var enhancedApps: Set<pid_t> = [] // AXEnhancedUserInterface slows Chrome: undone on stop
    private let dryRun = CommandLine.arguments.contains("--dry-run")
    /// Accessibility requests to our own process are served on the calling thread, which would
    /// drive SwiftUI off the main thread and trap. Our own windows are never snap targets anyway.
    private let ownPID = getpid()

    static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenuBarItem", "AXDisclosureTriangle", "AXComboBox", "AXDockItem",
        "AXIncrementor", "AXColorWell", "AXRow", "AXTab",
    ]
    /// Elements whose children are only visible inside their frame.
    static let clippingRoles: Set<String> = ["AXScrollArea", "AXWebArea", "AXWindow"]
    static let chromiumApps: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    init() {
        AXUIElementSetMessagingTimeout(systemWide, 0.08) // never let a busy app stall the scan
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: nil) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            else { return }
            self?.queue.async { self?.tunedApps.remove(pid); self?.enhancedApps.remove(pid) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.queue.sync { self?.untune() }
        }
    }

    /// Main thread only.
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    /// Serialized after any scan in flight, so its targets can't land after the clear.
    func stop() {
        isRunning = false
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            lastScan = nil
            untune()
            DispatchQueue.main.async { [weak self] in self?.onTargets?([]) }
        }
    }

    private func tick() {
        guard let p = CGEvent(source: nil)?.location else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Pointer still: rescan only occasionally (UI can change under it).
        if let last = lastScan, hypot(last.point.x - p.x, last.point.y - p.y) < 3, now - last.time < 0.4 { return }
        lastScan = (p, now)
        let targets = scan(at: p)
        DispatchQueue.main.async { [weak self] in self?.onTargets?(targets) }
    }

    /// Clickable element frames near `p` (global, top-left origin).
    func scan(at p: CGPoint, budget: TimeInterval = 0.04) -> [CGRect] {
        // The pointer may be just outside the window that holds the nearest button (e.g. above
        // the Dock), so also probe a ring of points around it and search every container hit.
        var roots: [AXUIElement] = []
        let ring = 36.0
        let probes = [p] + (0..<8).map { i -> CGPoint in
            let a = Double(i) * .pi / 4
            return CGPoint(x: p.x + ring * cos(a), y: p.y + ring * sin(a))
        }
        let probeDeadline = ProcessInfo.processInfo.systemUptime + budget / 2
        for q in probes {
            if !roots.isEmpty && ProcessInfo.processInfo.systemUptime > probeDeadline { break } // busy app
            var hitRef: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(q.x), Float(q.y), &hitRef) == .success,
                  let hit = hitRef, pid(of: hit) != ownPID else { continue }
            let root = container(of: hit)
            if !roots.contains(where: { CFEqual($0, root) }) {
                tune(app: hit)
                roots.append(root)
            }
        }
        guard !roots.isEmpty else { return [] }

        let region = CGRect(x: p.x - searchRadius, y: p.y - searchRadius, width: searchRadius * 2, height: searchRadius * 2)
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var found: [CGRect] = []
        var visited = 0
        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray

        // Best-first: always expand the element closest to the pointer, so a scan cut short
        // by the time budget (first contact with a busy app) has already found the nearest targets.
        // Children are queued with their parent's distance and re-queued once their own is known.
        var heap = NodeHeap()
        for r in roots { heap.push(Node(element: r, key: 0, clip: .infinite, values: nil)) }
        while var node = heap.pop(), visited < 2500, ProcessInfo.processInfo.systemUptime < deadline {
            if node.values == nil {
                visited += 1
                var valuesRef: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(node.element, names,
                                                             AXCopyMultipleAttributeOptions(rawValue: 0),
                                                             &valuesRef) == .success,
                      let values = valuesRef as? [AnyObject], values.count == 4 else { continue }
                node.values = values
                if let f = Self.frame(position: values[1], size: values[2]) {
                    if !f.intersects(region.intersection(node.clip)) { continue } // prune: nothing below can be near or visible
                    if let role = values[0] as? String, Self.clippingRoles.contains(role) { node.clip = node.clip.intersection(f) }
                    let d = Self.distance(p, f)
                    if d > node.key + 1 { // farther than its parent suggested: requeue by its own distance
                        node.key = d
                        heap.push(node)
                        continue
                    }
                }
            }
            guard let values = node.values else { continue }
            // only the part inside its scroll area / web view / window is on screen (web pages expose
            // links scrolled out of view with real coordinates, e.g. under the toolbar)
            if let role = values[0] as? String, Self.clickableRoles.contains(role),
               let f = Self.frame(position: values[1], size: values[2])?.intersection(node.clip), Self.usable(f) {
                found.append(f)
            }
            if let children = values[3] as? [AXUIElement] {
                for c in children { heap.push(Node(element: c, key: node.key, clip: node.clip, values: nil)) }
            }
        }
        // drop exact duplicates (same element reached twice, or button + identical cell)
        var unique: [CGRect] = []
        for f in found where !unique.contains(where: { Magnet.same($0, f) }) { unique.append(f) }
        return unique
    }

    private func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : 0
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return Double(hypot(dx, dy))
    }

    /// The top-level container below the application: a window, the menu bar, the Dock list.
    private func container(of element: AXUIElement) -> AXUIElement {
        if let window: AXUIElement = attribute(element, kAXWindowAttribute) { return window } // one call, not a climb
        var root = element
        for _ in 0..<60 {
            guard let parent: AXUIElement = attribute(root, kAXParentAttribute),
                  (attribute(parent, kAXRoleAttribute) as String?) != kAXApplicationRole else { break }
            root = parent
        }
        return root
    }

    /// Sizes that make sense as snap targets: skip slivers and huge areas (whole rows, panes).
    private static func usable(_ f: CGRect) -> Bool {
        f.width >= 6 && f.height >= 6 && f.width <= 480 && f.height <= 160
    }

    private static func frame(position: AnyObject, size: AnyObject) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Chromium and Electron only build their accessibility tree for assistive apps
    /// that ask for it; without this, web pages expose no buttons or links.
    /// AXManualAccessibility is enough for current Chromium; AXEnhancedUserInterface (which slows
    /// Chrome and upsets window managers) is only the fallback for older ones, and is undone on stop.
    private func tune(app hit: AXUIElement) {
        let pid = pid(of: hit)
        guard !dryRun, pid != 0, pid != ownPID, !tunedApps.contains(pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        var result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if result != .success, let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           Self.chromiumApps.contains(id) {
            result = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            if result == .success { enhancedApps.insert(pid) }
        }
        if result != .cannotComplete { tunedApps.insert(pid) } // retry only when the app was too busy to answer
    }

    private func untune() {
        for pid in enhancedApps {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            tunedApps.remove(pid)
        }
        enhancedApps = []
    }
}

private struct Node {
    let element: AXUIElement
    var key: Double // distance from the pointer (lower bound until the element's frame is read)
    var clip: CGRect // visible area of the enclosing scroll areas and window
    var values: [AnyObject]?
}

/// Minimal binary min-heap on `key`.
private struct NodeHeap {
    private var items: [Node] = []

    mutating func push(_ n: Node) {
        items.append(n)
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i].key < items[parent].key else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> Node? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < items.count && items[l].key < items[m].key { m = l }
            if r < items.count && items[r].key < items[m].key { m = r }
            if m == i { break }
            items.swapAt(i, m)
            i = m
        }
        return top
    }
}
