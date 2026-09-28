import AppKit
import ApplicationServices

@main
@MainActor
enum MacTaskbarApp {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--dump") {
            dump()
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
            print("  [\(w.appName)] \(w.displayTitle) frame=\(w.frame) minimized=\(w.isMinimized) focused=\(w.isFocused)")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let source = WindowSource()
    private let observer = WindowObserver()
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

        rebuildBars()

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
        bars = NSScreen.screens.map { screen in
            let bar = TaskbarBar(screen: screen)
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
            apply(windows)
            if dirty {
                dirty = false
                refresh()
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
