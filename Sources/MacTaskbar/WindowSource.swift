import AppKit
import ApplicationServices

/// Hashable wrapper so AX window elements can be tracked across refreshes.
struct WindowKey: Hashable {
    let element: AXUIElement

    static func == (a: WindowKey, b: WindowKey) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
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

    var element: AXUIElement { key.element }
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

    /// Regular apps except ourselves.
    @MainActor
    static func current() -> EnumerationContext {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map { App(app: $0, isHidden: $0.isHidden) }
        return EnumerationContext(
            apps: apps,
            frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }
}

/// Enumerates and manipulates windows via the Accessibility API.
/// AX calls block up to the messaging timeout per unresponsive app, so all of them run on a
/// private serial queue; results are delivered to the main thread as immutable snapshots.
/// Note: AX only reports windows on the current Space.
final class WindowSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.cwbudde.mactaskbar.ax", qos: .userInitiated)

    // Confined to `queue`.
    /// First-seen order, so buttons don't jump around when focus changes.
    private var order: [WindowKey: Int] = [:]
    private var nextIndex = 0
    /// One line per app describing the last enumeration; used for logging and `--dump`.
    private var report: [String] = []
    private var lastReport: [pid_t: String] = [:]

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
        var result: [TaskWindow] = []
        var report: [pid_t: String] = [:]

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

            var kinds: [String] = []
            var accepted = 0
            for element in elements {
                let role: String? = copyAttribute(element, kAXRoleAttribute)
                let subrole: String? = copyAttribute(element, kAXSubroleAttribute)
                let canMinimize = copyAttribute(element, kAXMinimizeButtonAttribute).flatMap { (button: AXUIElement) in
                    copyAttribute(button, kAXEnabledAttribute) as Bool?
                } ?? false
                kinds.append("\(role ?? "nil")/\(subrole ?? "nil")\(canMinimize ? "+min" : "")")
                guard let pos = copyPoint(element, kAXPositionAttribute),
                      let size = copySize(element, kAXSizeAttribute) else { continue }
                let isMinimized: Bool = copyAttribute(element, kAXMinimizedAttribute) ?? false
                guard Self.isTaskWindow(
                    role: role, subrole: subrole, size: size, isMinimized: isMinimized, canMinimize: canMinimize)
                else { continue }
                accepted += 1

                // AX uses top-left origin with y pointing down; convert to Cocoa coordinates.
                let frame = CGRect(x: pos.x, y: primaryHeight - pos.y - size.height,
                                   width: size.width, height: size.height)
                let key = WindowKey(element: element)
                result.append(TaskWindow(
                    key: key,
                    app: app,
                    title: copyAttribute(element, kAXTitleAttribute) ?? "",
                    frame: frame,
                    isMinimized: isMinimized,
                    isFocused: focused.map { CFEqual($0, element) } ?? false,
                    isAppHidden: entry.isHidden
                ))
            }
            report[pid] = "\(name): \(elements.count) windows, \(accepted) shown, role/subrole \(kinds)"
        }

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

    /// Unhides the app (main thread), then raises and focuses the window on the AX queue.
    @MainActor
    func focus(_ w: TaskWindow, completion: @escaping @MainActor () -> Void) {
        if w.app.isHidden { w.app.unhide() }
        perform(completion) {
            if w.isMinimized {
                AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            // Bringing the app to front via AX works even though our panel never becomes active.
            let appElement = AXUIElementCreateApplication(w.app.processIdentifier)
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
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
          let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
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
