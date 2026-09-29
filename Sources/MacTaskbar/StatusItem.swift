import AppKit

/// Menu bar item with Settings… and Quit; the app's only entry point besides the bars.
@MainActor
final class StatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onSettings: () -> Void

    init(onSettings: @escaping () -> Void) {
        self.onSettings = onSettings
        super.init()

        item.button?.image = NSImage(
            systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: "MacTaskbar")

        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacTaskbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func openSettings() {
        onSettings()
    }
}
