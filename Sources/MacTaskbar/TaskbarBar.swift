import AppKit

/// One bar pinned to the bottom (or top) edge of a screen, showing one button per window.
@MainActor
final class TaskbarBar: NSObject {
    private static let spacing: CGFloat = 4
    private static let inset: CGFloat = 6

    let screenFrame: CGRect
    private let maxButtonWidth: CGFloat
    private let buttonHeight: CGFloat
    private let panel: NSPanel
    private let stack = NSStackView()
    private var signature: [String] = []

    var onClick: ((TaskWindow) -> Void)?
    var onClose: ((TaskWindow) -> Void)?

    init(screen: NSScreen, settings: Settings) {
        screenFrame = screen.frame
        maxButtonWidth = settings.maxButtonWidth
        let height = settings.barHeight
        buttonHeight = height - 6
        // At the top, sit below the menu bar (the top of the visible frame).
        let y = settings.position == .top ? screen.visibleFrame.maxY - height : screen.frame.minY
        let frame = CGRect(x: screen.frame.minX, y: y, width: screen.frame.width, height: height)
        panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        let menu = NSMenu()
        menu.addItem(withTitle: "Quit MacTaskbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        background.menu = menu

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.inset),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -Self.inset),
        ])

        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    func update(_ windows: [TaskWindow]) {
        let sig = windows.map { "\($0.key.id)|\($0.displayTitle)|\($0.isVisible)|\($0.isFocused)" }
        guard sig != signature else { return }
        signature = sig

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !windows.isEmpty else { return }

        // Shrink buttons evenly when the bar gets crowded.
        let available = screenFrame.width - 2 * Self.inset - CGFloat(windows.count - 1) * Self.spacing
        let width = min(maxButtonWidth, floor(available / CGFloat(windows.count)))

        for w in windows {
            let button = TaskButton(task: w, width: width, height: buttonHeight)
            button.target = self
            button.action = #selector(buttonClicked(_:))

            let menu = NSMenu()
            let item = menu.addItem(withTitle: "Close Window", action: #selector(closeClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = button
            button.menu = menu

            stack.addArrangedSubview(button)
        }
    }

    func showMessage(_ text: String) {
        guard signature != ["message"] else { return }
        signature = ["message"]
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(NSTextField(labelWithString: text))
    }

    @objc private func buttonClicked(_ sender: TaskButton) {
        onClick?(sender.task)
    }

    @objc private func closeClicked(_ sender: NSMenuItem) {
        guard let button = sender.representedObject as? TaskButton else { return }
        onClose?(button.task)
    }
}

final class TaskButton: NSButton {
    let task: TaskWindow

    init(task: TaskWindow, width: CGFloat, height: CGFloat) {
        self.task = task
        super.init(frame: .zero)

        title = " " + task.displayTitle
        toolTip = task.title.isEmpty ? task.appName : "\(task.appName) — \(task.title)"
        if let icon = task.app.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 18, height: 18)
            image = icon
        }
        imagePosition = .imageLeading
        alignment = .left
        isBordered = false
        cell?.lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true

        wantsLayer = true
        layer?.cornerRadius = 5
        let tint: NSColor =
            task.isFocused
            ? .controlAccentColor.withAlphaComponent(0.35)
            : .labelColor.withAlphaComponent(0.08)
        layer?.backgroundColor = tint.cgColor
        alphaValue = task.isVisible ? 1 : 0.5

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
