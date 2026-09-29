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
