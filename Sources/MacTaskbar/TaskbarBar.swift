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
        let position: Settings.Position

        @MainActor init(screen: NSScreen, settings: Settings) {
            screenFrame = screen.frame
            maxButtonWidth = settings.maxButtonWidth
            position = settings.position
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
        panel.setAccessibilityTitle("Taskbar")

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

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @objc private func displayOptionsChanged() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        buttons.values.forEach { $0.highContrast = contrast }
    }

    func close() {
        panel.orderOut(nil)
    }

    /// Updates the buttons in place: known windows keep their button, new ones fade in, closed
    /// ones are removed. Rebuilding every button on each change flickers and loses hover state.
    func update(_ windows: [TaskWindow]) {
        let sig = windows.map {
            "\($0.key.id)|\($0.displayTitle)|\($0.isVisible)|\($0.isFocused)|\($0.isOnCurrentSpace)|\($0.badge ?? "")"
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
    var isHovered = false {
        didSet { if isHovered != oldValue { stateChanged() } }
    }
    var isPressed = false {
        didSet { if isPressed != oldValue { stateChanged() } }
    }
    /// "Increase contrast" in System Settings → Accessibility → Display: outline every button.
    var highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
        didSet { needsDisplay = true }
    }
    private let badge = BadgeView()

    override class var cellClass: AnyClass? {
        get { TaskButtonCell.self }
        set {}
    }

    init(task: TaskWindow, width: CGFloat, height: CGFloat) {
        self.task = task
        super.init(frame: .zero)

        imagePosition = .imageLeading
        alignment = .left
        isBordered = false
        cell?.lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
        wantsLayer = true

        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: width)
        addSubview(badge)
        NSLayoutConstraint.activate([
            widthConstraint, heightAnchor.constraint(equalToConstant: height),
            // Over the top-right corner of the 18 pt icon.
            badge.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -7),
        ])
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        configure(oldApp: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
        badge.text = task.badge
        // VoiceOver reads this instead of the padded title, including what the tint conveys.
        var label = [task.title.isEmpty ? task.appName : "\(task.appName) — \(task.title)"]
        if task.isFocused { label.append("focused") }
        if task.isMinimized {
            label.append("minimized")
        } else if task.isAppHidden {
            label.append("hidden")
        }
        if !task.isOnCurrentSpace { label.append("on another Space") }
        if let badge = task.badge { label.append("badge \(badge)") }
        setAccessibilityLabel(label.joined(separator: ", "))
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func stateChanged() {
        Log.events.debug(
            "Button \(self.task.key.id, privacy: .public): hover \(self.isHovered), pressed \(self.isPressed)")
        needsDisplay = true
    }

    /// Drawn rather than set as layer colours: dynamic colours then resolve for the current
    /// appearance (light/dark, increased contrast) on every redraw, including after it changes.
    override func draw(_ dirtyRect: NSRect) {
        let strength: CGFloat = isPressed ? 2 : isHovered ? 1 : 0
        let tint: NSColor =
            task.isFocused
            ? .controlAccentColor.withAlphaComponent(0.35 + 0.1 * strength)
            : .labelColor.withAlphaComponent(0.08 + 0.08 * strength)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        tint.setFill()
        shape.fill()
        if highContrast {
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            shape.stroke()
        }
        super.draw(dirtyRect)
    }
}

/// Reports press and release (also when the pointer is dragged off and back on) to its button.
private final class TaskButtonCell: NSButtonCell {
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        super.highlight(flag, withFrame: cellFrame, in: controlView)
        (controlView as? TaskButton)?.isPressed = flag
    }
}

/// The app's Dock badge (unread count and the like) as a red capsule.
private final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String? {
        didSet {
            label.stringValue = text ?? ""
            isHidden = text == nil
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 12),
            widthAnchor.constraint(greaterThanOrEqualTo: heightAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
