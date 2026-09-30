import AppKit
import ServiceManagement
import SwiftUI

/// The Settings window. The app has no main menu or Dock icon (`LSUIElement`), so it is opened from
/// the status bar item and has to activate the app itself.
@MainActor
final class SettingsWindow {
    private let settings: Settings
    private let loginItem = LoginItemModel()
    private var window: NSWindow?

    init(settings: Settings) {
        self.settings = settings
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(
                    rootView: SettingsView(settings: settings, loginItem: loginItem)))
            window.title = "MacTaskbar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // Launch at login may have been changed in System Settings meanwhile.
        loginItem.reload()
        // Activation is cooperative and may be refused (e.g. when another app keeps focus), so also
        // order the window front regardless: it must never open behind other apps' windows.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

/// Launch-at-login state for the view. Kept in an `ObservableObject` instead of `@State`: SwiftUI's
/// `@State` is a macro whose plugin ships only with Xcode, not with the Command Line Tools.
@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var status = LoginItem.status

    /// `requiresApproval`: registered, but waiting for the user in System Settings.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        reload()
    }

    func reload() { status = LoginItem.status }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var loginItem: LoginItemModel

    var body: some View {
        Form {
            Section("Screens") {
                // In a grouped form the label is a separate text; without an explicit label the
                // controls have no accessible name.
                Toggle("Menu bar display only", isOn: $settings.menuBarScreenOnly)
                    .accessibilityLabel("Menu bar display only")
                ForEach(NSScreen.screens, id: \.self) { screen in
                    Toggle(
                        screen.localizedName,
                        isOn: Binding(
                            get: { settings.isEnabled(screen) },
                            set: { settings.setEnabled($0, for: screen) })
                    )
                    .accessibilityLabel(screen.localizedName)
                    .disabled(settings.menuBarScreenOnly)
                }
            }
            Section("Bar") {
                Picker("Position", selection: $settings.position) {
                    Text("Bottom").tag(Settings.Position.bottom)
                    Text("Top").tag(Settings.Position.top)
                }
                .accessibilityLabel("Position")
                Picker("Windows from", selection: $settings.spaces) {
                    Text("All Spaces").tag(Settings.SpaceMode.all)
                    Text("Current Space").tag(Settings.SpaceMode.current)
                }
                .accessibilityLabel("Windows from")
                .disabled(!Spaces.isAvailable)
                Toggle("Keep windows clear of the bar", isOn: $settings.keepWindowsClear)
                    .accessibilityLabel("Keep windows clear of the bar")
                LabeledContent("Height") {
                    Slider(value: $settings.barHeight, in: Settings.heightRange, step: 2)
                        .accessibilityLabel("Height")
                    Text("\(Int(settings.barHeight)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                LabeledContent("Button width") {
                    Slider(value: $settings.maxButtonWidth, in: Settings.buttonWidthRange, step: 10)
                        .accessibilityLabel("Button width")
                    Text("\(Int(settings.maxButtonWidth)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            Section("General") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })
                )
                .accessibilityLabel("Launch at login")
                if loginItem.status == .requiresApproval {
                    HStack {
                        Text("Allow MacTaskbar in Login Items to finish.").foregroundStyle(.secondary)
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
