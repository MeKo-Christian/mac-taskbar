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
        if let i = CommandLine.arguments.firstIndex(of: "--render-buttons"), i + 1 < CommandLine.arguments.count {
            renderButtons(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
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
        let context = EnumerationContext.current(allSpaces: true)
        print("Spaces: current \(context.spaces.current.sorted()) of \(context.spaces.all.sorted())")
        let (windows, report) = WindowSource().windowsAndReport(context)
        print("\nPer app:")
        report.forEach { print("  \($0)") }
        print("\nShown windows (\(windows.count)):")
        for w in windows {
            print(
                "  [\(w.appName)] \(w.displayTitle) id=\(w.windowID.map { "\($0)" } ?? "nil") frame=\(w.frame) "
                    + "minimized=\(w.isMinimized) focused=\(w.isFocused) spaces=\(w.spaces.sorted())"
                    + (w.isOnCurrentSpace ? "" : " (other Space)") + (w.badge.map { " badge=\($0)" } ?? ""))
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

    /// Renders a button in every state, light and dark, to `buttons-<appearance>.png` in `dir`, to
    /// check the styles without Screen Recording permission.
    private static func renderButtons(to dir: URL) {
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        func sample(_ title: String, minimized: Bool = false, focused: Bool = false, badge: String? = nil)
            -> TaskWindow
        {
            TaskWindow(
                key: WindowKey(element: AXUIElementCreateApplication(getpid())), app: finder ?? .current,
                title: title, frame: .zero, isMinimized: minimized, isFocused: focused, isAppHidden: false,
                spaces: [], isOnCurrentSpace: true, badge: badge)
        }
        let states: [(TaskWindow, (TaskButton) -> Void)] = [
            (sample("Normal"), { _ in }),
            (sample("Hover"), { $0.isHovered = true }),
            (sample("Pressed"), { $0.isPressed = true }),
            (sample("Focused", focused: true), { _ in }),
            (sample("Focused, hover", focused: true), { $0.isHovered = true }),
            (sample("Focused, pressed", focused: true), { $0.isPressed = true }),
            (sample("Minimized", minimized: true), { _ in }),
            (sample("Badge", badge: "3"), { _ in }),
            (sample("Badge, long", badge: "120"), { _ in }),
            (sample("Increase contrast"), { $0.highContrast = true }),
        ]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let size = NSSize(width: 220, height: CGFloat(states.count) * 30 + 8)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
                defer: false)
            window.appearance = NSAppearance(named: name)
            let content = NSBox(frame: NSRect(origin: .zero, size: size))
            content.boxType = .custom
            content.borderWidth = 0
            content.fillColor = .windowBackgroundColor
            window.contentView = content
            for (i, (task, apply)) in states.enumerated() {
                let button = TaskButton(task: task, width: 200, height: 26)
                button.alphaValue = button.targetAlpha
                apply(button)
                content.contentView?.addSubview(button)
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                    button.topAnchor.constraint(equalTo: content.topAnchor, constant: 4 + CGFloat(i) * 30),
                ])
            }
            content.layoutSubtreeIfNeeded()
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: rep)
            let url = dir.appendingPathComponent("buttons-\(name.rawValue).png")
            do {
                try rep.representation(using: .png, properties: [:])?.write(to: url)
                print("Wrote \(url.path)")
            } catch {
                print("Writing \(url.path) failed: \(error)")
            }
        }
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

    /// Focuses the window titled `text` (else the first whose title contains it), as a click on its
    /// button would, then prints what ended up focused. For testing focus without clicking.
    private static func focus(matching text: String) {
        let source = WindowSource()
        let (windows, _) = source.windowsAndReport(.current(allSpaces: true))
        guard
            let w = windows.first(where: { $0.displayTitle == text })
                ?? windows.first(where: { $0.displayTitle.localizedCaseInsensitiveContains(text) })
        else {
            print("No window matching \"\(text)\"")
            return
        }
        print("Focusing [\(w.appName)] \(w.displayTitle) minimized=\(w.isMinimized) appHidden=\(w.isAppHidden)")
        var done = false
        source.focus(w) { done = true }
        while !done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let (after, _) = source.windowsAndReport(.current(allSpaces: true))
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let focused = after.first(where: \.isFocused).map { "[\($0.appName)] \($0.displayTitle)" } ?? "none"
        print("Frontmost app: \(front)\nFocused window: \(focused)")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let source = WindowSource()
    private let observer = WindowObserver()
    private lazy var keepOut = KeepOut(source: source)
    private let autoHide = AutoHide()
    private let settings = Settings()
    private var settingsChange: AnyCancellable?
    private lazy var settingsWindow = SettingsWindow(settings: settings)
    private var statusItem: StatusItem?
    private let onboarding = OnboardingWindow()
    private lazy var dockHint = DockHintWindow(settings: settings)
    private var bars: [TaskbarBar] = []
    private var timer: Timer?
    private var lastTrusted: Bool?
    private var lastCounts: [Int] = []
    /// An enumeration is running on the AX queue; further refreshes only mark it `dirty`.
    private var refreshing = false
    private var dirty = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Started from \(Bundle.main.bundlePath, privacy: .public)")
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
        keepOut.onMouseUp = { [weak self] in self?.refreshSoon() }

        // AX notifications drive updates; this slow poll only reconciles missed events and
        // retries attaching to apps that were still launching.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    @objc private func screensChanged() {
        Log.app.debug("Screens or settings changed")
        rebuildBars()
        refresh()
    }

    private func rebuildBars() {
        let layouts = NSScreen.screens.filter(settings.isEnabled).map {
            TaskbarBar.Layout(screen: $0, settings: settings)
        }
        // Screen parameters also change when nothing a bar depends on did (Dock, display wake);
        // keep the bars then, recreating them flickers.
        guard layouts != bars.map(\.layout) else { return }
        autoHide.bars = []
        bars.forEach { $0.close() }
        bars = layouts.map { layout in
            let bar = TaskbarBar(layout: layout)
            bar.onClick = { [weak self] w in self?.clicked(w) }
            bar.onClose = { [weak self] w in
                self?.source.close(w) { self?.refreshSoon() }
            }
            return bar
        }
        autoHide.bars = settings.autoHide ? bars : []
        Log.app.info("Bars rebuilt: \(self.bars.count) on \(NSScreen.screens.count) screens")
    }

    @objc private func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrusted {
            Log.app.info("AXIsProcessTrusted = \(trusted)")
            lastTrusted = trusted
            // Also catches a permission revoked while running (within one reconciliation poll).
            if trusted { onboarding.close() } else { onboarding.show() }
        }
        // After the Accessibility onboarding, never on top of it.
        dockHint.update(dockCoversBar: trusted && dockCoversBar)
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
        let context = EnumerationContext.current(allSpaces: settings.spaces == .all)
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
        if settings.keepWindowsClear && !settings.autoHide {
            keepOut.apply(zip(bars, perBar).map { (layout: $0.layout, windows: $1) })
        }

        let counts = perBar.map(\.count)
        if counts != lastCounts {
            Log.app.info("Windows per bar: \(counts, privacy: .public)")
            lastCounts = counts
        }
    }

    /// A visible Dock at the bottom reserves space there (the visible frame starts above it) and sits
    /// above the bar's window level, covering a bottom bar on that screen.
    private var dockCoversBar: Bool {
        bars.contains { bar in
            bar.layout.position == .bottom
                && NSScreen.screens.contains { $0.frame == bar.screenFrame && $0.visibleFrame.minY > $0.frame.minY + 1 }
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
