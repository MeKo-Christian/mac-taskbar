import AppKit
import ApplicationServices

/// Hashable wrapper so AX window elements can be tracked across refreshes.
struct WindowKey: Hashable {
    let element: AXUIElement

    static func == (a: WindowKey, b: WindowKey) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// A standard top-level window of a regular app, as seen through the Accessibility API.
struct TaskWindow {
    let key: WindowKey
    let app: NSRunningApplication
    let title: String
    /// Frame in Cocoa screen coordinates (origin at bottom-left of the primary screen).
    let frame: CGRect
    let isMinimized: Bool
    let isFocused: Bool

    var element: AXUIElement { key.element }
    var appName: String { app.localizedName ?? "?" }
    var displayTitle: String { title.isEmpty ? appName : title }
    /// Minimized windows and windows of hidden apps are not visible on screen.
    var isVisible: Bool { !isMinimized && !app.isHidden }
}

/// Enumerates and manipulates windows via the Accessibility API.
/// Note: AX only reports windows on the current Space.
@MainActor
final class WindowSource {
    /// First-seen order, so buttons don't jump around when focus changes.
    private var order: [WindowKey: Int] = [:]
    private var nextIndex = 0

    init() {
        // Keep unresponsive apps from stalling the bar (global timeout, in seconds).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// One line per app describing the last enumeration; used for logging and `--dump`.
    private(set) var report: [String] = []
    private var lastReport: [pid_t: String] = [:]

    func windows() -> [TaskWindow] {
        let focused = focusedWindow()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var result: [TaskWindow] = []
        var report: [pid_t: String] = [:]

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            if pid == getpid() { continue }
            let appElement = AXUIElementCreateApplication(pid)
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
            let (elements, error): ([AXUIElement]?, AXError) = copyAttributeResult(appElement, kAXWindowsAttribute)
            guard let elements else {
                report[pid] = "\(name): kAXWindows failed: \(describe(error))"
                continue
            }

            var subroles: [String] = []
            var accepted = 0
            for element in elements {
                let role: String? = copyAttribute(element, kAXRoleAttribute)
                let subrole: String? = copyAttribute(element, kAXSubroleAttribute)
                subroles.append(subrole ?? "nil")
                guard let pos = copyPoint(element, kAXPositionAttribute),
                      let size = copySize(element, kAXSizeAttribute) else { continue }
                guard Self.isTaskWindow(role: role, subrole: subrole, size: size) else { continue }
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
                    isMinimized: copyAttribute(element, kAXMinimizedAttribute) ?? false,
                    isFocused: focused.map { CFEqual($0, element) } ?? false
                ))
            }
            report[pid] = "\(name): \(elements.count) windows, \(accepted) shown, subroles \(subroles)"
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

    func focus(_ w: TaskWindow) {
        if w.app.isHidden { w.app.unhide() }
        if w.isMinimized {
            AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        // Bringing the app to front via AX works even though our panel never becomes active.
        let appElement = AXUIElementCreateApplication(w.app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    func minimize(_ w: TaskWindow) {
        AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    func close(_ w: TaskWindow) {
        if let button: AXUIElement = copyAttribute(w.element, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    /// Standard windows, plus large role-only windows (Electron/Java apps often lack a proper subrole).
    private static func isTaskWindow(role: String?, subrole: String?, size: CGSize) -> Bool {
        if subrole == kAXStandardWindowSubrole { return true }
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

    private func focusedWindow() -> AXUIElement? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(front.processIdentifier)
        return copyAttribute(appElement, kAXFocusedWindowAttribute)
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
