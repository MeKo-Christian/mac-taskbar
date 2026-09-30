import AppKit
import ApplicationServices
import SwiftUI

/// Explains why MacTaskbar needs the Accessibility permission and leads to the right pane in System
/// Settings. Shown while the app is not trusted: at launch, and again when the permission is revoked.
@MainActor
final class OnboardingWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView()))
            window.title = "MacTaskbar Needs Accessibility Access"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }
}

struct OnboardingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow MacTaskbar to see and control windows").font(.headline)
            Text(
                """
                MacTaskbar reads the open windows of other apps and focuses, minimizes or closes them \
                when you click a button. macOS only allows this for apps with Accessibility access.
                """)
            Text(
                """
                Open Privacy & Security → Accessibility and turn on MacTaskbar. This window closes \
                by itself as soon as access is granted.
                """
            ).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                Button("Open Privacy & Security…") { Self.openAccessibilitySettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize()
    }

    private static func openAccessibilitySettings() {
        // Adds MacTaskbar to the list (switched off) so the user only has to flip the switch.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Suggests hiding the Dock while it sits at the bottom of a screen with a bottom bar: the Dock's
/// window level is above the bar's, so it covers the bar. Shown once per launch until dismissed for
/// good, and closed by itself once the Dock no longer covers a bar.
@MainActor
final class DockHintWindow {
    private static let dismissedKey = "dockHintDismissed"

    private let settings: Settings
    private var window: NSWindow?
    private var shownThisLaunch = false

    init(settings: Settings) {
        self.settings = settings
    }

    func update(dockCoversBar: Bool) {
        guard dockCoversBar else {
            window?.close()
            return
        }
        guard !shownThisLaunch, !UserDefaults.standard.bool(forKey: Self.dismissedKey) else { return }
        shownThisLaunch = true
        Log.app.info("Dock covers the bar: showing the hint")
        show()
    }

    private func show() {
        if window == nil {
            let view = DockHintView(
                hideDock: { [weak self] in self?.hideDock() },
                moveBarToTop: { [weak self] in
                    self?.settings.position = .top
                    self?.window?.close()
                },
                dismiss: { [weak self] in
                    UserDefaults.standard.set(true, forKey: Self.dismissedKey)
                    self?.window?.close()
                })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "The Dock Covers the Bar"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Does what `defaults write com.apple.dock autohide -bool true; killall Dock` does: the Dock
    /// reads the setting when it starts, and launchd restarts it right away. The screens' visible
    /// frames change then, which closes this window. Falls back to Desktop & Dock settings.
    private func hideDock() {
        let dock = "com.apple.dock" as CFString
        CFPreferencesSetAppValue("autohide" as CFString, kCFBooleanTrue, dock)
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Dock"]
        do {
            guard CFPreferencesAppSynchronize(dock) else { throw CocoaError(.fileWriteUnknown) }
            try killall.run()
            Log.app.info("Dock set to hide automatically")
        } catch {
            Log.app.error("Hiding the Dock failed (\(error, privacy: .public)); opening Desktop & Dock")
            if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

struct DockHintView: View {
    let hideDock: () -> Void
    let moveBarToTop: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hide the Dock to see the whole bar").font(.headline)
            Text(
                """
                The Dock sits at the bottom of the screen, in front of MacTaskbar's bar. Set it to \
                hide automatically: it still slides in when the pointer reaches the bottom edge.
                """)
            Text("You can also move the bar to the top, or change this later in System Settings → Desktop & Dock.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Don't Show Again", action: dismiss)
                Spacer()
                Button("Move Bar to Top", action: moveBarToTop)
                Button("Hide Dock Automatically", action: hideDock)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize()
    }
}
