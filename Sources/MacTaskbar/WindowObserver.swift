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
        /// App-level notifications whose registration failed transiently; retried on every sync.
        var pending: [String]
        /// Windows with all window-level notifications registered.
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
        for (pid, obs) in apps where !obs.pending.isEmpty {
            apps[pid]?.pending = register(obs.pending, on: obs.appElement, with: obs.observer).transient
        }
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
            obs.windows.formIntersection(current)
            // A window counts as observed only once every registration went through; otherwise the
            // next refresh retries it (already registered notifications report success again).
            for key in current.subtracting(obs.windows)
            where register(Self.windowNotifications, on: key.element, with: obs.observer).transient.isEmpty {
                obs.windows.insert(key)
            }
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
        let result = register(Self.appNotifications, on: appElement, with: observer)
        // Nothing registered usually means the app is still launching; retry on the next sync.
        if result.registered == 0 {
            Log.events.debug("Attach to \(name, privacy: .public) failed: \(result.failures, privacy: .public)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        apps[pid] = AppObservation(observer: observer, appElement: appElement, pending: result.transient)
        let partial = result.failures.isEmpty ? "" : ", partial: \(result.failures)"
        Log.events.debug("Attached to \(name, privacy: .public)\(partial, privacy: .public)")
    }

    /// Registers `names` on `element`. `transient` lists the ones worth retrying (the app was busy);
    /// other errors, e.g. an unsupported notification, are permanent and only reported.
    private func register(
        _ names: [String], on element: AXUIElement, with observer: AXObserver
    ) -> (registered: Int, transient: [String], failures: [String]) {
        var registered = 0
        var transient: [String] = []
        var failures: [String] = []
        for name in names {
            let error = AXObserverAddNotification(observer, element, name as CFString, selfPointer)
            switch error {
            case .success, .notificationAlreadyRegistered:
                registered += 1
            case .cannotComplete:
                transient.append(name)
                failures.append("\(name): \(describe(error))")
            default:
                failures.append("\(name): \(describe(error))")
            }
        }
        return (registered, transient, failures)
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
