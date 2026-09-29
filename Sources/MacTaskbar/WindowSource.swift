import AppKit
import ApplicationServices

/// Private, but stable for years and used by AltTab, Rectangle and yabai: the `CGWindowID` behind
/// an AX window element. Not available through any public API.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Private, as used by AltTab: an AX element from a remote token (pid + element ID). The only way
/// to reach windows on other Spaces, which `kAXWindows` leaves out.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// Identity of a window across refreshes: its `CGWindowID` when the window server reports one
/// (also needed for previews and cross-Space tracking), otherwise the AX element itself.
struct WindowKey: Hashable {
    let element: AXUIElement
    let windowID: CGWindowID?

    init(element: AXUIElement) {
        self.element = element
        var id: CGWindowID = 0
        windowID = _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// Equality and hashing share one discriminator: the window ID when present, else the AX
    /// element. A key with an ID never equals one without, so a window whose ID lookup failed
    /// once is treated as a new window rather than breaking the `Hashable` contract.
    static func == (a: WindowKey, b: WindowKey) -> Bool {
        switch (a.windowID, b.windowID) {
        case (let x?, let y?): x == y
        case (nil, nil): CFEqual(a.element, b.element)
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        if let windowID {
            hasher.combine(windowID)
        } else {
            hasher.combine(CFHash(element))
        }
    }

    /// Short, stable description for change detection and logs.
    var id: String { windowID.map { "\($0)" } ?? "ax\(CFHash(element))" }
}

/// A standard top-level window of a regular app, as seen through the Accessibility API.
/// An immutable snapshot: built on the AX queue, consumed on the main thread.
struct TaskWindow: @unchecked Sendable {
    let key: WindowKey
    let app: NSRunningApplication
    let title: String
    /// Frame in Cocoa screen coordinates (origin at bottom-left of the primary screen).
    let frame: CGRect
    let isMinimized: Bool
    let isFocused: Bool
    let isAppHidden: Bool
    /// Empty when the Space functions are unavailable or the window server reports none.
    let spaces: Set<UInt64>
    let isOnCurrentSpace: Bool

    var element: AXUIElement { key.element }
    var windowID: CGWindowID? { key.windowID }
    var appName: String { app.localizedName ?? "?" }
    var displayTitle: String { title.isEmpty ? appName : title }
    /// Minimized windows and windows of hidden apps are not visible on screen.
    var isVisible: Bool { !isMinimized && !isAppHidden }
}

/// Main-thread state an enumeration needs, captured up front so the AX queue never touches
/// NSWorkspace or NSScreen.
struct EnumerationContext: @unchecked Sendable {
    struct App {
        let app: NSRunningApplication
        let isHidden: Bool
    }

    let apps: [App]
    let frontmostPid: pid_t?
    let primaryHeight: CGFloat
    let spaces: Spaces.Snapshot
    /// List windows on every Space, not only the ones the displays currently show.
    let allSpaces: Bool

    /// Regular apps except ourselves.
    @MainActor
    static func current(allSpaces: Bool) -> EnumerationContext {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map { App(app: $0, isHidden: $0.isHidden) }
        return EnumerationContext(
            apps: apps,
            frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            primaryHeight: NSScreen.screens.first?.frame.height ?? 0,
            spaces: Spaces.snapshot(),
            allSpaces: allSpaces && Spaces.isAvailable)
    }
}

/// Enumerates and manipulates windows via the Accessibility API.
/// AX calls block up to the messaging timeout per unresponsive app, so all of them run on a
/// private serial queue; results are delivered to the main thread as immutable snapshots.
/// `kAXWindows` only reports windows on the current Space (plus minimized ones); windows on other
/// Spaces come from the window server and are reached via remembered or remote-token elements.
final class WindowSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.cwbudde.mactaskbar.ax", qos: .userInitiated)

    // Confined to `queue`.
    /// First-seen order, so buttons don't jump around when focus changes.
    private var order: [WindowKey: Int] = [:]
    private var nextIndex = 0
    /// Elements of windows seen before, kept while the window exists: they stay valid when the
    /// window leaves the current Space, so it needs no remote-token lookup then.
    private var known: [CGWindowID: WindowKey] = [:]
    /// Windows on other Spaces whose remote-token lookup failed, with their Spaces at the time;
    /// retried only once they move, so the reconciliation poll doesn't repeat the lookup.
    private var unresolved: [CGWindowID: Set<UInt64>] = [:]
    /// One line per app describing the last enumeration; used for logging and `--dump`.
    private var report: [String] = []
    private var lastReport: [pid_t: String] = [:]

    /// Incremented per focus request, so a delayed activation check can tell it was superseded.
    @MainActor private var focusRequest = 0

    init() {
        // Keep unresponsive apps from stalling the bar (global timeout, in seconds).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// Enumerates on the AX queue and delivers the snapshot on the main thread.
    func windows(_ ctx: EnumerationContext, completion: @escaping @MainActor ([TaskWindow]) -> Void) {
        queue.async { [self] in
            let start = DispatchTime.now()
            let result = enumerate(ctx)
            let ms = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            if ms > 100 { Log.ax.debug("Enumeration took \(ms) ms") }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Blocking variant for `--dump`: the snapshot plus the per-app report.
    func windowsAndReport(_ ctx: EnumerationContext) -> ([TaskWindow], [String]) {
        queue.sync { (enumerate(ctx), report) }
    }

    private func enumerate(_ ctx: EnumerationContext) -> [TaskWindow] {
        dispatchPrecondition(condition: .onQueue(queue))
        let focused = focusedWindow(ctx.frontmostPid)
        let primaryHeight = ctx.primaryHeight
        let (offSpace, existing) = ctx.allSpaces ? offSpaceWindows(ctx) : ([:], nil)
        var result: [TaskWindow] = []
        var report: [pid_t: String] = [:]
        var seen: Set<CGWindowID> = []

        for entry in ctx.apps {
            let app = entry.app
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
            let (elements, error): ([AXUIElement]?, AXError) = copyAttributeResult(appElement, kAXWindowsAttribute)
            guard let elements else {
                report[pid] = "\(name): kAXWindows failed: \(describe(error))"
                continue
            }
            let listed = elements.map(WindowKey.init)
            let (others, resolved) = offSpaceKeys(
                pid, offSpace[pid, default: [:]], listed: Set(listed.compactMap(\.windowID)))

            var kinds: [String] = []
            var accepted = 0
            for key in listed + others {
                let element = key.element
                let role: String? = copyAttribute(element, kAXRoleAttribute)
                let subrole: String? = copyAttribute(element, kAXSubroleAttribute)
                let canMinimize =
                    copyAttribute(element, kAXMinimizeButtonAttribute).flatMap { (button: AXUIElement) in
                        copyAttribute(button, kAXEnabledAttribute) as Bool?
                    } ?? false
                kinds.append("\(role ?? "nil")/\(subrole ?? "nil")\(canMinimize ? "+min" : "")")
                guard let pos = copyPoint(element, kAXPositionAttribute),
                    let size = copySize(element, kAXSizeAttribute)
                else { continue }
                let isMinimized: Bool = copyAttribute(element, kAXMinimizedAttribute) ?? false
                guard
                    Self.isTaskWindow(
                        role: role, subrole: subrole, size: size, isMinimized: isMinimized, canMinimize: canMinimize)
                else { continue }
                let spaces = key.windowID.map(Spaces.spaces(of:)) ?? []
                // A window on no known Space can't be placed; treat it as on the current one.
                let isOnCurrentSpace = spaces.isEmpty || !spaces.isDisjoint(with: ctx.spaces.current)
                guard isOnCurrentSpace || ctx.allSpaces else { continue }
                accepted += 1
                if let id = key.windowID {
                    known[id] = key
                    seen.insert(id)
                }

                // AX uses top-left origin with y pointing down; convert to Cocoa coordinates.
                let frame = CGRect(
                    x: pos.x, y: primaryHeight - pos.y - size.height,
                    width: size.width, height: size.height)
                result.append(
                    TaskWindow(
                        key: key,
                        app: app,
                        title: copyAttribute(element, kAXTitleAttribute) ?? "",
                        frame: frame,
                        isMinimized: isMinimized,
                        isFocused: focused.map { CFEqual($0, element) } ?? false,
                        isAppHidden: entry.isHidden,
                        spaces: spaces,
                        isOnCurrentSpace: isOnCurrentSpace
                    ))
            }
            let fromOthers =
                others.isEmpty ? "" : " + \(others.count) on other Spaces (\(resolved) via remote token)"
            report[pid] = "\(name): \(elements.count) windows\(fromOthers), \(accepted) shown, role/subrole \(kinds)"
        }

        // Forget closed windows only: a window keeps its element or failed lookup while the user
        // switches Spaces. Without the window list (current Space only), keep the shown ones.
        known = known.filter { existing?.contains($0.key) ?? seen.contains($0.key) }
        unresolved = unresolved.filter { existing?.contains($0.key) ?? false }

        logChanges(report)
        self.report = report.values.sorted()

        // Stable ordering: keep known windows in place, append new ones, forget closed ones.
        let present = Set(result.map(\.key))
        order = order.filter { present.contains($0.key) }
        for w in result where order[w.key] == nil {
            order[w.key] = nextIndex
            nextIndex += 1
        }
        return result.sorted { order[$0.key]! < order[$1.key]! }
    }

    /// Windows of the given apps that are only on Spaces the displays don't show, with those Spaces,
    /// by pid, plus the IDs of all their windows. Helper windows at the normal level are on no Space
    /// and drop out here.
    private func offSpaceWindows(
        _ ctx: EnumerationContext
    ) -> (windows: [pid_t: [CGWindowID: Set<UInt64>]], existing: Set<CGWindowID>) {
        let pids = Set(ctx.apps.map(\.app.processIdentifier))
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [pid_t: [CGWindowID: Set<UInt64>]] = [:]
        var existing: Set<CGWindowID> = []
        for entry in info {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                let id = entry[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            existing.insert(id)
            guard entry[kCGWindowLayer as String] as? Int == 0 else { continue }
            let spaces = Spaces.spaces(of: id)
            guard !spaces.isDisjoint(with: ctx.spaces.all), spaces.isDisjoint(with: ctx.spaces.current) else {
                continue
            }
            result[pid, default: [:]][id] = spaces
        }
        return (result, existing)
    }

    /// Elements for an app's windows on other Spaces that `kAXWindows` left out: remembered ones,
    /// else looked up via remote tokens. Also returns how many needed that lookup.
    private func offSpaceKeys(
        _ pid: pid_t, _ windows: [CGWindowID: Set<UInt64>], listed: Set<CGWindowID>
    ) -> (keys: [WindowKey], resolved: Int) {
        let missing = windows.filter { !listed.contains($0.key) }
        let unknown = missing.filter { known[$0.key] == nil && unresolved[$0.key] != $0.value }
        var resolved = 0
        if !unknown.isEmpty {
            let found = resolveRemote(pid, Set(unknown.keys))
            for (id, spaces) in unknown {
                if let key = found[id] { known[id] = key } else { unresolved[id] = spaces }
            }
            resolved = found.count
        }
        return (missing.keys.sorted().compactMap { known[$0] }, resolved)
    }

    /// Tries remote tokens with one element ID after another until all `ids` are found, as AltTab
    /// does. Bounded in time, so an app with many elements can't stall the enumeration for long.
    private func resolveRemote(_ pid: pid_t, _ ids: Set<CGWindowID>) -> [CGWindowID: WindowKey] {
        let start = DispatchTime.now()
        let deadline = start + Self.remoteLookupBudget
        // Token layout: pid (4 bytes), 0 (4), "coco" (4), element ID (8).
        var token = Data(count: 20)
        token.withUnsafeMutableBytes {
            $0.storeBytes(of: pid, toByteOffset: 0, as: pid_t.self)
            $0.storeBytes(of: 0x636f_636f, toByteOffset: 8, as: UInt32.self)
        }
        var found: [CGWindowID: WindowKey] = [:]
        var elementID: UInt64 = 0
        while found.count < ids.count, elementID < Self.maxRemoteElementID, DispatchTime.now() < deadline {
            token.withUnsafeMutableBytes { $0.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self) }
            elementID += 1
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else {
                continue
            }
            let key = WindowKey(element: element)
            // A window's buttons and other children report its window ID too.
            if let id = key.windowID, ids.contains(id), copyAttribute(element, kAXRoleAttribute) == kAXWindowRole {
                found[id] = key
            }
        }
        let ms = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        Log.ax.debug(
            "Remote-token lookup for pid \(pid): \(found.count)/\(ids.count) windows, \(elementID) ids, \(ms) ms")
        return found
    }

    private static let remoteLookupBudget = DispatchTimeInterval.milliseconds(100)
    private static let maxRemoteElementID: UInt64 = 10_000

    /// Unhides the app (main thread), then raises and focuses the window on the AX queue.
    /// Some activations are ignored, e.g. while the app is still unhiding; those fall back to
    /// cooperative activation via `NSRunningApplication`. Successful ones raise the window again.
    @MainActor
    func focus(_ w: TaskWindow, completion: @escaping @MainActor () -> Void) {
        focusRequest += 1
        let request = focusRequest
        let previous = NSWorkspace.shared.frontmostApplication
        if w.app.isHidden { w.app.unhide() }
        let checkActivation: @MainActor () -> Void = {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationCheckDelay) {
                MainActor.assumeIsolated {
                    guard request == self.focusRequest else { return completion() }
                    if w.app.isActive {
                        // Activation lands asynchronously and brings the app's key window forward,
                        // which wins over the raise when that window is on another display.
                        self.perform(completion) { Self.raise(w) }
                    } else if NSWorkspace.shared.frontmostApplication == previous {
                        // The AX activation had no effect (and the user didn't move on meanwhile).
                        self.activate(w, completion: completion)
                    } else {
                        completion()
                    }
                }
            }
        }
        perform(checkActivation) {
            if w.isMinimized {
                AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            Self.raise(w)
            // Bringing the app to front via AX works even though our panel never becomes active.
            let appElement = AXUIElementCreateApplication(w.app.processIdentifier)
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// How long an AX activation gets to take effect before the fallback kicks in.
    private static let activationCheckDelay: TimeInterval = 0.1

    @MainActor
    private func activate(_ w: TaskWindow, completion: @escaping @MainActor () -> Void) {
        Log.ax.debug("AX activation of \(w.appName, privacy: .public) ignored, activating via NSRunningApplication")
        NSApp.yieldActivation(to: w.app)
        w.app.activate()
        // Activation brings the app's own front window forward; raise the requested one again.
        perform(completion) { Self.raise(w) }
    }

    private static func raise(_ w: TaskWindow) {
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    func minimize(_ w: TaskWindow, completion: @escaping @MainActor () -> Void) {
        perform(completion) {
            AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    func close(_ w: TaskWindow, completion: @escaping @MainActor () -> Void) {
        perform(completion) {
            if let button: AXUIElement = copyAttribute(w.element, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
        }
    }

    private func perform(_ completion: @escaping @MainActor () -> Void, _ action: @escaping () -> Void) {
        queue.async {
            action()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion() } }
        }
    }

    /// Standard windows, plus large role-only windows (Electron/Java apps often lack a proper subrole).
    /// Minimized windows report subrole `AXDialog`, so they are accepted by role alone. Document
    /// windows can also report `AXDialog` (TextEdit, until the app is first activated); unlike real
    /// dialogs such as About boxes they have an enabled minimize button. Floating panels
    /// (`AXFloatingWindow`) and sheets (not in `kAXWindows`) are never listed.
    private static func isTaskWindow(
        role: String?, subrole: String?, size: CGSize, isMinimized: Bool, canMinimize: Bool
    ) -> Bool {
        if subrole == kAXStandardWindowSubrole { return true }
        if isMinimized && role == kAXWindowRole { return true }
        if subrole == kAXDialogSubrole && role == kAXWindowRole && canMinimize { return true }
        guard role == kAXWindowRole, subrole == nil || subrole == kAXUnknownSubrole else { return false }
        return size.width >= 100 && size.height >= 60
    }

    /// Logs only the apps whose enumeration result changed, so polling doesn't flood the log.
    private func logChanges(_ report: [pid_t: String]) {
        for (pid, line) in report where lastReport[pid] != line {
            Log.ax.debug("\(line, privacy: .public)")
        }
        lastReport = report
    }

    private func focusedWindow(_ pid: pid_t?) -> AXUIElement? {
        guard let pid else { return nil }
        return copyAttribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
    }
}

private func copyAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

private func copyAttributeResult<T>(_ element: AXUIElement, _ name: String) -> (T?, AXError) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (error == .success ? value as? T : nil, error)
}

func describe(_ error: AXError) -> String {
    switch error {
    case .success: "success"
    case .apiDisabled: "apiDisabled (process not trusted for Accessibility)"
    case .cannotComplete: "cannotComplete (app busy or timed out)"
    case .noValue: "noValue"
    case .attributeUnsupported: "attributeUnsupported"
    case .notImplemented: "notImplemented"
    case .invalidUIElement: "invalidUIElement"
    case .illegalArgument: "illegalArgument"
    case .failure: "failure"
    default: "AXError \(error.rawValue)"
    }
}

private func copyAXValue(_ element: AXUIElement, _ name: String) -> AXValue? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
        let raw, CFGetTypeID(raw) == AXValueGetTypeID()
    else { return nil }
    return (raw as! AXValue)
}

private func copyPoint(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let value = copyAXValue(element, name) else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &point) ? point : nil
}

private func copySize(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let value = copyAXValue(element, name) else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(value, .cgSize, &size) ? size : nil
}
