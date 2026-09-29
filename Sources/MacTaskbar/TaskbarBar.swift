import AppKit

/// One bar pinned to the bottom (or top) edge of a screen, showing one button per window.
@MainActor
final class TaskbarBar: NSObject {
    private static let spacing: CGFloat = 4
    private static let inset: CGFloat = 6

    /// Everything a bar is built from. Bars are only recreated when it changes.
    struct Layout: Equatable {
        let screenFrame: CGRect
        let frame: CGRect
        let maxButtonWidth: CGFloat

        @MainActor init(screen: NSScreen, settings: Settings) {
            screenFrame = screen.frame
            maxButtonWidth = settings.maxButtonWidth
            let height = settings.barHeight
            // At the top, sit below the menu bar (the top of the visible frame).
            let y = settings.position == .top ? screen.visibleFrame.maxY - height : screen.frame.minY
            frame = CGRect(x: screen.frame.minX, y: y, width: screen.frame.width, height: height)
        }
    }

    let layout: Layout
    var screenFrame: CGRect { layout.screenFrame }
    private var maxButtonWidth: CGFloat { layout.maxButtonWidth }
    private var buttonHeight: CGFloat { layout.frame.height - 6 }
    private let panel: NSPanel
    private let stack = NSStackView()
    private var signature: [String] = []
    /// The button of each shown window, by `WindowKey.id`.
    private var buttons: [String: TaskButton] = [:]

    var onClick: ((TaskWindow) -> Void)?
    var onClose: ((TaskWindow) -> Void)?

    init(layout: Layout) {
        self.layout = layout
        panel = NSPanel(
            contentRect: layout.frame, styleMask: [.borderless, .nonactivatingPanel],
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

    /// Updates the buttons in place: known windows keep their button, new ones fade in, closed
    /// ones are removed. Rebuilding every button on each change flickers and loses hover state.
    func update(_ windows: [TaskWindow]) {
        let sig = windows.map {
            "\($0.key.id)|\($0.displayTitle)|\($0.isVisible)|\($0.isFocused)|\($0.isOnCurrentSpace)"
        }
        guard sig != signature else { return }
        if signature == ["message"] { stack.arrangedSubviews.forEach { $0.removeFromSuperview() } }
        signature = sig

        // Shrink buttons evenly when the bar gets crowded.
        let count = CGFloat(max(windows.count, 1))
        let available = screenFrame.width - 2 * Self.inset - (count - 1) * Self.spacing
        let width = min(maxButtonWidth, floor(available / count))

        let ids = Set(windows.map(\.key.id))
        let gone = buttons.filter { !ids.contains($0.key) }
        for (id, button) in gone {
            button.removeFromSuperview()
            buttons[id] = nil
        }
        let kept = stack.arrangedSubviews.compactMap { $0 as? TaskButton }

        var added: [TaskButton] = []
        let ordered = windows.map { w -> TaskButton in
            if let button = buttons[w.key.id] {
                button.task = w
                return button
            }
            let button = makeButton(w)
            buttons[w.key.id] = button
            added.append(button)
            return button
        }
        let reordered = kept != ordered.filter { !added.contains($0) }
        for (i, button) in ordered.enumerated()
        where i >= stack.arrangedSubviews.count || stack.arrangedSubviews[i] !== button {
            stack.insertArrangedSubview(button, at: i)
        }

        // Existing buttons slide to their new width and position; new ones fade in.
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !kept.isEmpty
        added.forEach { $0.alphaValue = animate ? 0 : $0.targetAlpha }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? 0.2 : 0
            context.allowsImplicitAnimation = animate
            for button in ordered {
                button.widthConstraint.animator().constant = width
                button.animator().alphaValue = button.targetAlpha
            }
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        Log.app.debug(
            "Bar update at x=\(Int(self.screenFrame.minX)): +\(added.count) −\(gone.count) =\(kept.count)\(reordered ? " reordered" : "", privacy: .public)"
        )
    }

    private func makeButton(_ w: TaskWindow) -> TaskButton {
        let button = TaskButton(task: w, width: maxButtonWidth, height: buttonHeight)
        button.target = self
        button.action = #selector(buttonClicked(_:))

        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Close Window", action: #selector(closeClicked(_:)), keyEquivalent: "")
        item.target = self
        button.menu = menu
        return button
    }

    func showMessage(_ text: String) {
        guard signature != ["message"] else { return }
        signature = ["message"]
        buttons = [:]
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(NSTextField(labelWithString: text))
    }

    @objc private func buttonClicked(_ sender: TaskButton) {
        onClick?(sender.task)
    }

    @objc private func closeClicked(_ sender: NSMenuItem) {
        // Found via the menu: a `representedObject` pointing back at the button would retain it.
        guard let button = buttons.values.first(where: { $0.menu === sender.menu }) else { return }
        onClose?(button.task)
    }
}

final class TaskButton: NSButton {
    var task: TaskWindow {
        didSet { configure(oldApp: oldValue.app) }
    }
    private(set) var widthConstraint: NSLayoutConstraint!
    /// Minimized windows and windows of hidden apps are dimmed.
    var targetAlpha: CGFloat { task.isVisible ? 1 : 0.5 }

    init(task: TaskWindow, width: CGFloat, height: CGFloat) {
        self.task = task
        super.init(frame: .zero)

        imagePosition = .imageLeading
        alignment = .left
        isBordered = false
        cell?.lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
        wantsLayer = true
        layer?.cornerRadius = 5

        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([widthConstraint, heightAnchor.constraint(equalToConstant: height)])
        configure(oldApp: nil)
    }

    /// Applies `task` to the button; called again whenever the window's state changes.
    private func configure(oldApp: NSRunningApplication?) {
        title = " " + task.displayTitle
        toolTip =
            (task.title.isEmpty ? task.appName : "\(task.appName) — \(task.title)")
            + (task.isOnCurrentSpace ? "" : " (on another Space)")
        if oldApp != task.app, let icon = task.app.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 18, height: 18)
            image = icon
        }
        let tint: NSColor =
            task.isFocused
            ? .controlAccentColor.withAlphaComponent(0.35)
            : .labelColor.withAlphaComponent(0.08)
        layer?.backgroundColor = tint.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
