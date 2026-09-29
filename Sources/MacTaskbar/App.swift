import AppKit
import ApplicationServices
import Combine

@main
@MainActor
enum MacTaskbarApp {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--dump") {
            dump()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--focus"), i + 1 < CommandLine.arguments.count {
            focus(matching: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--login-item") {
            loginItem(i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "status")
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Prints what the AX enumeration sees and exits. When run from a terminal, the
    /// Accessibility check applies to the terminal app, not to MacTaskbar.app.
    private static func dump() {
        print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
        let (windows, report) = WindowSource().windowsAndReport(.current())
        print("\nPer app:")
        report.forEach { print("  \($0)") }
        print("\nShown windows (\(windows.count)):")
        for w in windows {
            print(
                "  [\(w.appName)] \(w.displayTitle) id=\(w.windowID.map { "\($0)" } ?? "nil") frame=\(w.frame) "
                    + "minimized=\(w.isMinimized) focused=\(w.isFocused)")
        }

        // Cross-check the private window IDs against the window server (needs no Screen Recording).
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var owners: [CGWindowID: pid_t] = [:]
        for entry in info {
            if let id = entry[kCGWindowNumber as String] as? CGWindowID,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t
            {
                owners[id] = pid
            }
        }
        let matching = windows.filter { w in w.windowID.flatMap { owners[$0] } == w.app.processIdentifier }
        print("\nWindow IDs matching CGWindowList (id + owner pid): \(matching.count)/\(windows.count)")
    }

    /// `register`, `unregister` or `status` of launch at login, as the Settings toggle does. Run the
    /// binary inside MacTaskbar.app: `SMAppService.mainApp` refers to the enclosing bundle.
    private static func loginItem(_ command: String) {
        switch command {
        case "register": LoginItem.setEnabled(true)
        case "unregister": LoginItem.setEnabled(false)
        default: break
        }
        print("Launch at login: \(LoginItem.describe(LoginItem.status))")
    }

    /// Focuses the first window whose title contains `text`, as a click on its button would, then
    /// prints what ended up focused. For testing focus without clicking.
    private static func focus(matching text: String) {
        let source = WindowSource()
        let (windows, _) = source.windowsAndReport(.current())
        guard let w = windows.first(where: { $0.displayTitle.localizedCaseInsensitiveContains(text) }) else {
            print("No window matching \"\(text)\"")
            return
        }
        print("Focusing [\(w.appName)] \(w.displayTitle) minimized=\(w.isMinimized) appHidden=\(w.isAppHidden)")
        var done = false
        source.focus(w) { done = true }
        while !done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let (after, _) = source.windowsAndReport(.current())
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let focused = after.first(where: \.isFocused).map { "[\($0.appName)] \($0.displayTitle)" } ?? "none"
        print("Frontmost app: \(front)\nFocused window: \(focused)")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let source = WindowSource()
    private let observer = WindowObserver()
    private let settings = Settings()
    private var settingsChange: AnyCancellable?
    private lazy var settingsWindow = SettingsWindow(settings: settings)
    private var statusItem: StatusItem?
    private var bars: [TaskbarBar] = []
    private var timer: Timer?
    private var lastTrusted: Bool?
    private var lastCounts: [Int] = []
    /// An enumeration is running on the AX queue; further refreshes only mark it `dirty`.
    private var refreshing = false
    private var dirty = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Started from \(Bundle.main.bundlePath, privacy: .public)")
        // Shows the system prompt pointing to Privacy & Security → Accessibility.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        statusItem = StatusItem { [weak self] in self?.settingsWindow.show() }
        rebuildBars()
        // `objectWillChange` fires before the new value is stored; rebuild on the next turn.
        settingsChange = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.screensChanged() } }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            workspace.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }

        observer.onChange = { [weak self] in self?.refresh() }

        // AX notifications drive updates; this slow poll only reconciles missed events and
        // retries attaching to apps that were still launching.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    @objc private func screensChanged() {
        rebuildBars()
        refresh()
    }

    private func rebuildBars() {
        bars.forEach { $0.close() }
        bars = NSScreen.screens.filter(settings.isEnabled).map { screen in
            let bar = TaskbarBar(screen: screen, settings: settings)
            bar.onClick = { [weak self] w in self?.clicked(w) }
            bar.onClose = { [weak self] w in
                self?.source.close(w) { self?.refreshSoon() }
            }
            return bar
        }
    }

    @objc private func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrusted {
            Log.app.info("AXIsProcessTrusted = \(trusted)")
            lastTrusted = trusted
        }
        guard trusted else {
            bars.forEach {
                $0.showMessage("Grant Accessibility access to MacTaskbar in System Settings → Privacy & Security")
            }
            return
        }

        // One enumeration at a time: a hung app delays the snapshot but never queues up work.
        guard !refreshing else {
            dirty = true
            return
        }
        refreshing = true
        let context = EnumerationContext.current()
        source.windows(context) { [weak self] windows in
            guard let self else { return }
            refreshing = false
            observer.sync(with: context.apps.map(\.app))
            // A change arrived meanwhile, so this snapshot may already be stale: skip it rather than
            // show outdated focus/minimized state while the follow-up enumeration runs.
            if dirty {
                dirty = false
                refresh()
            } else {
                apply(windows)
            }
        }
    }

    private func apply(_ windows: [TaskWindow]) {
        observer.observe(windows)

        var perBar = Array(repeating: [TaskWindow](), count: bars.count)
        for w in windows {
            if let i = barIndex(for: w.frame) { perBar[i].append(w) }
        }
        for (bar, windows) in zip(bars, perBar) { bar.update(windows) }

        let counts = perBar.map(\.count)
        if counts != lastCounts {
            Log.app.info("Windows per bar: \(counts, privacy: .public)")
            lastCounts = counts
        }
    }

    /// Each window belongs to the screen containing its center, else the one it overlaps most.
    private func barIndex(for frame: CGRect) -> Int? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let i = bars.firstIndex(where: { $0.screenFrame.contains(center) }) { return i }
        let areas = bars.map { bar -> CGFloat in
            let r = bar.screenFrame.intersection(frame)
            return r.isNull ? 0 : r.width * r.height
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }) else { return nil }
        return areas[best] > 0 ? best : 0
    }

    /// Windows taskbar semantics: clicking the focused window minimizes it, otherwise focus it.
    private func clicked(_ w: TaskWindow) {
        if w.isFocused && w.isVisible {
            source.minimize(w) { [weak self] in self?.refreshSoon() }
        } else {
            source.focus(w) { [weak self] in self?.refreshSoon() }
        }
    }

    /// Gives the target app a moment to apply an action before re-reading state.
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}
