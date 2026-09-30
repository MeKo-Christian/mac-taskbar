import AppKit

/// Hides the bars until the pointer rests at their outer edge, as the Dock's auto-hide does. The
/// hidden bars stay ordered in, invisible and click-through, so events reach the apps below and the
/// global monitor sees the pointer there.
@MainActor
final class AutoHide {
    /// How long the pointer has to rest at the edge before a bar shows: crossing the strip on the way
    /// to the menu bar, a window's title bar or another screen must not flash it.
    private static let revealDelay: TimeInterval = 0.15
    private static let hideDelay: TimeInterval = 0.5
    private static let hideCheckInterval: TimeInterval = 0.1
    /// Thickness of the strip along the bar's outer edge that reveals it.
    private static let edge: CGFloat = 2
    /// The pointer may stray this far off a shown bar before the hide delay starts.
    private static let slack: CGFloat = 4

    /// The bars to manage; empty turns auto-hide off.
    var bars: [TaskbarBar] = [] {
        didSet { barsChanged() }
    }

    private var monitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var revealTimer: Timer?
    private var hideTimer: Timer?
    /// When the pointer left each shown bar, by `ObjectIdentifier` of the bar.
    private var leftAt: [ObjectIdentifier: Date] = [:]
    /// A context menu of a bar stays open after the pointer left the bar.
    private var menusOpen = 0

    init() {
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.menusOpen += 1 }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.menusOpen = max((self?.menusOpen ?? 1) - 1, 0) }
            },
        ]
    }

    /// The strip along the bar's outer edge: the screen edge for a bottom bar, the menu bar's lower
    /// edge for a top bar. Cocoa coordinates.
    static func trigger(for layout: TaskbarBar.Layout) -> CGRect {
        let f = layout.frame
        switch layout.position {
        case .bottom: return CGRect(x: f.minX, y: f.minY - 1, width: f.width, height: edge + 1)
        case .top: return CGRect(x: f.minX, y: f.maxY - edge, width: f.width, height: edge + 1)
        }
    }

    private func barsChanged() {
        leftAt = [:]
        revealTimer?.invalidate()
        revealTimer = nil
        if bars.isEmpty {
            hideTimer?.invalidate()
            hideTimer = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        } else if monitor == nil {
            // Global monitors only see other apps' events; over a shown bar the hide timer takes over.
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
        }
    }

    private func pointerMoved() {
        guard revealTimer == nil else { return }
        let p = NSEvent.mouseLocation
        guard bars.contains(where: { !$0.isRevealed && Self.trigger(for: $0.layout).contains(p) }) else { return }
        revealTimer = Timer.scheduledTimer(withTimeInterval: Self.revealDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealIfResting() }
        }
    }

    private func revealIfResting() {
        revealTimer = nil
        let p = NSEvent.mouseLocation
        for bar in bars
        where !bar.isRevealed && Self.trigger(for: bar.layout).insetBy(dx: 0, dy: -Self.edge).contains(p) {
            Log.app.debug("Auto-hide: showing bar at x=\(Int(bar.screenFrame.minX))")
            bar.setRevealed(true)
        }
        if hideTimer == nil && bars.contains(where: \.isRevealed) {
            hideTimer = Timer.scheduledTimer(withTimeInterval: Self.hideCheckInterval, repeats: true) {
                [weak self] _ in MainActor.assumeIsolated { self?.hideIfLeft() }
            }
        }
    }

    /// Polled while a bar is shown: the pointer is over our own panel then, which global monitors
    /// don't report.
    private func hideIfLeft() {
        let p = NSEvent.mouseLocation
        let now = Date()
        for bar in bars where bar.isRevealed {
            let id = ObjectIdentifier(bar)
            let inside = bar.layout.frame.insetBy(dx: -Self.slack, dy: -Self.slack).contains(p)
            // Also stay while a context menu is open or a button is being pressed.
            if inside || menusOpen > 0 || NSEvent.pressedMouseButtons != 0 {
                leftAt[id] = nil
            } else if let left = leftAt[id] {
                if now.timeIntervalSince(left) >= Self.hideDelay {
                    Log.app.debug("Auto-hide: hiding bar at x=\(Int(bar.screenFrame.minX))")
                    bar.setRevealed(false)
                    leftAt[id] = nil
                }
            } else {
                leftAt[id] = now
            }
        }
        if !bars.contains(where: \.isRevealed) {
            hideTimer?.invalidate()
            hideTimer = nil
        }
    }
}
