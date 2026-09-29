import ServiceManagement

/// Launch at login via `SMAppService`. The system is the source of truth (the user can also toggle
/// it in System Settings → General → Login Items), so nothing is stored in `UserDefaults`.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// `requiresApproval` counts as enabled: registered, but waiting for the user in System Settings.
    static var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Launch at login \(enabled ? "register" : "unregister") failed: \(error, privacy: .public)")
        }
        Log.app.info("Launch at login: \(describe(status), privacy: .public)")
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }
}
