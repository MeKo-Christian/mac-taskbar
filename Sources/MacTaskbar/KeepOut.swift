import AppKit

/// Keeps windows from ending under a bar. macOS can't reserve a screen strip (`visibleFrame` only
/// leaves out the menu bar and Dock), so zoomed, tiled and edge-resized windows reach under the
/// bar; they are shrunk via AX to end at its edge instead, as window managers like Rectangle do.
/// Only windows reaching the screen edge are adjusted: one parked partly off-screen is left alone.
@MainActor
final class KeepOut {
    private static let tolerance: CGFloat = 1
    /// At most this many adjustments per window within `budgetInterval`: an app that applies a new
    /// frame only partly (or late) would otherwise be shrunk step by step.
    private static let budget = 3
    private static let budgetInterval: TimeInterval = 10

    /// Called when a drag or resize that adjustments waited for has ended.
    var onMouseUp: () -> Void = {}

    private let source: WindowSource
    /// The frame each window had when it was last adjusted, then the frame the adjustment left it
    /// with. Either one coming back means the app refused (part of) the new frame and retrying would
    /// loop; any other frame, e.g. from zooming again, makes the window eligible again.
    private var attempted: [WindowKey: CGRect] = [:]
    /// When each window was adjusted recently, for `budget`.
    private var adjusted: [WindowKey: [Date]] = [:]
    private var awaitingMouseUp = false
    private var monitor: Any?

    init(source: WindowSource) {
        self.source = source
        // Global monitors only see other apps' events, which is where drags and resizes happen.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }
    }

    /// Adjusts the windows of one snapshot, each against the bar it is shown on.
    func apply(_ assignments: [(layout: TaskbarBar.Layout, windows: [TaskWindow])]) {
        let frames = Dictionary(
            assignments.flatMap(\.windows).map { ($0.key, $0.frame) }, uniquingKeysWith: { a, _ in a })
        attempted = attempted.filter { frames[$0.key] == $0.value }
        let now = Date()
        adjusted = adjusted.compactMapValues { dates in
            let recent = dates.filter { now.timeIntervalSince($0) < Self.budgetInterval }
            return recent.isEmpty ? nil : recent
        }

        // Mid-drag or mid-resize the frame is still changing; wait for the mouse to come up.
        guard NSEvent.pressedMouseButtons == 0 else {
            awaitingMouseUp = true
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for (layout, windows) in assignments {
            let topLimit =
                NSScreen.screens.first { $0.frame == layout.screenFrame }?.visibleFrame.maxY ?? layout.screenFrame.maxY
            for w in windows where w.isVisible && w.isOnCurrentSpace && attempted[w.key] == nil {
                guard
                    let target = Self.target(
                        window: w.frame, bar: layout.frame, screen: layout.screenFrame, position: layout.position)
                else { continue }
                attempted[w.key] = w.frame
                guard adjusted[w.key, default: []].count < Self.budget else {
                    Log.app.info(
                        "Keep-out: [\(w.appName, privacy: .public)] id=\(w.key.id, privacy: .public) keeps resisting, left alone"
                    )
                    continue
                }
                adjusted[w.key, default: []].append(now)
                source.setFrame(w, to: target, topLimit: topLimit, primaryHeight: primaryHeight) { [weak self] result in
                    if let result, self?.attempted[w.key] == w.frame { self?.attempted[w.key] = result }
                    let got = result.map(Self.describe) ?? "nothing (full-screen or AX failure)"
                    Log.app.info(
                        "Keep-out: [\(w.appName, privacy: .public)] id=\(w.key.id, privacy: .public) \(Self.describe(w.frame), privacy: .public) → \(Self.describe(target), privacy: .public), got \(got, privacy: .public)"
                    )
                }
            }
        }
    }

    /// The frame `window` should have so it ends at the bar's edge, or nil if it can stay.
    /// All frames in Cocoa coordinates.
    static func target(window w: CGRect, bar: CGRect, screen: CGRect, position: Settings.Position) -> CGRect? {
        let t = tolerance
        // Screen-sized windows (games, presentations) cover the bar on purpose.
        if w.insetBy(dx: -t, dy: -t).contains(screen) { return nil }
        switch position {
        case .bottom:
            // The bottom edge lies inside the bar's strip: zoomed, tiled or resized to the edge.
            // Below the screen edge it was parked there on purpose.
            guard w.minY >= screen.minY - t, w.minY < bar.maxY - t, w.maxY > bar.maxY else { return nil }
            return CGRect(x: w.minX, y: bar.maxY, width: w.width, height: w.maxY - bar.maxY)
        case .top:
            // The bar sits right below the menu bar, so a window reaching under it has its title bar
            // covered and can't even be dragged away.
            guard w.maxY > bar.minY + t, w.minY < bar.minY else { return nil }
            return CGRect(x: w.minX, y: w.minY, width: w.width, height: bar.minY - w.minY)
        }
    }

    private func mouseUp() {
        guard awaitingMouseUp else { return }
        awaitingMouseUp = false
        onMouseUp()
    }

    private static func describe(_ r: CGRect) -> String {
        "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))×\(Int(r.height)))"
    }
}
