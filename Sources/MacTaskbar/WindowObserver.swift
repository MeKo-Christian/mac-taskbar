import AppKit
import ApplicationServices

/// Subscribes to AX notifications, one `AXObserver` per app, and reports changes through
/// `onChange`. Bursts (e.g. many moved/resized events while dragging) are coalesced.
@MainActor
final class WindowObserver {
    var onChange: () -> Void = {}

    private struct AppObservation {
        let observer: AXObserver
        let appElement: AXUIElement
        var windows: Set<WindowKey> = []
    }

    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
    ]
    private static let coalesceDelay: TimeInterval = 0.05

    private var apps: [pid_t: AppObservation] = [:]
    private var pending: DispatchWorkItem?

    /// Attaches to running regular apps not yet observed and detaches from terminated ones.
    /// Also retries apps whose attach failed earlier (e.g. still launching).
    func sync(with running: [NSRunningApplication]) {
        let pids = Set(running.map(\.processIdentifier))
        for pid in apps.keys where !pids.contains(pid) { detach(pid) }
        for app in running where apps[app.processIdentifier] == nil { attach(app) }
    }

    /// Registers per-window notifications for newly seen windows and forgets vanished ones.
    func observe(_ windows: [TaskWindow]) {
        let byPid = Dictionary(grouping: windows) { $0.app.processIdentifier }
        for (pid, var obs) in apps {
            let current = Set(byPid[pid, default: []].map(\.key))
            for key in obs.windows.subtracting(current) {
                for name in Self.windowNotifications {
                    AXObserverRemoveNotification(obs.observer, key.element, name as CFString)
                }
            }
            for key in current.subtracting(obs.windows) {
                for name in Self.windowNotifications {
                    AXObserverAddNotification(obs.observer, key.element, name as CFString, selfPointer)
                }
            }
            obs.windows = current
            apps[pid] = obs
        }
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let name = app.localizedName ?? "pid \(pid)"
        var created: AXObserver?
        guard AXObserverCreate(pid, observerCallback, &created) == .success, let observer = created else {
            Log.events.debug("Observer for \(name, privacy: .public) not created")
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        var failures: [String] = []
        for notification in Self.appNotifications {
            let error = AXObserverAddNotification(observer, appElement, notification as CFString, selfPointer)
            if error != .success && error != .notificationAlreadyRegistered {
                failures.append("\(notification): \(describe(error))")
            }
        }
        // All registrations failing usually means the app is still launching; retry on the next sync.
        if failures.count == Self.appNotifications.count {
            Log.events.debug("Attach to \(name, privacy: .public) failed: \(failures, privacy: .public)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        apps[pid] = AppObservation(observer: observer, appElement: appElement)
        let partial = failures.isEmpty ? "" : ", partial: \(failures)"
        Log.events.debug("Attached to \(name, privacy: .public)\(partial, privacy: .public)")
    }

    private func detach(_ pid: pid_t) {
        guard let obs = apps.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs.observer), .defaultMode)
        Log.events.debug("Detached from pid \(pid)")
    }

    fileprivate func received(_ notification: String) {
        Log.events.debug("\(notification, privacy: .public)")
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceDelay, execute: work)
    }

    private var selfPointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}

/// Runs on the main run loop, where the observers' sources are scheduled.
private func observerCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let target = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { target.received(name) }
}
