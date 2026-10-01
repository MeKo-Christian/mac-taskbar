import AppKit

/// One bar pinned to the bottom (or top) edge of a screen, showing one button per window (or per
/// app, with *Group windows by app*).
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
        /// Hidden until the pointer rests at the bar's edge (see `AutoHide`).
        let autoHide: Bool
        let groupByApp: Bool

        @MainActor init(screen: NSScreen, settings: Settings) {
            screenFrame = screen.frame
            maxButtonWidth = settings.maxButtonWidth
            position = settings.position
            autoHide = settings.autoHide
            groupByApp = settings.groupByApp
            let height = settings.barHeight
            // At the top, sit below the menu bar (the top of the visible frame).
            let y = settings.position == .top ? screen.visibleFrame.maxY - height : screen.frame.minY
            frame = CGRect(x: screen.frame.minX, y: y, width: screen.frame.width, height: height)
        }
    }

    /// What a button's context menu or middle click asks for.
    enum Action {
        case close, newWindow, hideApp, quitApp
        case moveTo(NSScreen)
    }

    let layout: Layout
    var screenFrame: CGRect { layout.screenFrame }
    private var maxButtonWidth: CGFloat { layout.maxButtonWidth }
    private var buttonHeight: CGFloat { layout.frame.height - 6 }
    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let stack = NSStackView()
    private var signature: [String] = []
    /// The button of each shown window, by `WindowKey.id`, or of each app (`buttonID`) when grouping.
    private var buttons: [String: TaskButton] = [:]
    /// While a button is dragged, updates wait: they would put it back mid-drag.
    private var isDragging = false
    /// Trackpad scrolling arrives in small steps; they add up to one window per `scrollStep`.
    private var scrollAmount: CGFloat = 0
    /// The window the last scroll focused. Focus changes land asynchronously, so quick scrolls
    /// continue from here rather than from the snapshot's focused window.
    private var cycled: (key: WindowKey, at: Date)?
    private static let scrollStep: CGFloat = 30
    private static let cycleMemory: TimeInterval = 1

    /// A plain click on a single window's button.
    var onClick: ((TaskWindow) -> Void)?
    var onAction: ((TaskWindow, Action) -> Void)?
    /// Scrolling over the bar, or picking a window from a group's list, focuses that window.
    var onActivate: ((TaskWindow) -> Void)?
    /// A button was dragged elsewhere: the bar's windows in their new order.
    var onReorder: (([TaskWindow]) -> Void)?
    /// False while auto-hide keeps the bar out of sight.
    private(set) var isRevealed = true

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

        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        // In a container, so hiding can slide it out of the panel, which clips it; sliding the panel
        // itself would show it on a screen next to that edge.
        let container = BarView(frame: CGRect(origin: .zero, size: layout.frame.size))
        background.frame = container.bounds
        background.autoresizingMask = [.width, .height]
        container.addSubview(background)
        panel.contentView = container
        // Scroll events over a button or the background reach the container up the responder chain.
        container.onScroll = { [weak self] event in self?.scroll(event) }

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

        if layout.autoHide { setRevealed(false, animated: false) }
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

    /// Slides the bar in from (or out to) its edge and fades it. A hidden bar stays ordered in but
    /// lets clicks through, so it can come back without being reordered above other panels.
    func setRevealed(_ revealed: Bool, animated: Bool = true) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        panel.ignoresMouseEvents = !revealed
        // Past the outer edge: below a bottom bar, above a top one.
        let outside = NSPoint(x: 0, y: layout.position == .bottom ? -layout.frame.height : layout.frame.height)
        let slide = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if revealed && slide { background.setFrameOrigin(outside) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.2 : 0
            panel.animator().alphaValue = revealed ? 1 : 0
            background.animator().setFrameOrigin(revealed || !slide ? .zero : outside)
        }
    }

    /// Updates the buttons in place: known windows keep their button, new ones fade in, closed
    /// ones are removed. Rebuilding every button on each change flickers and loses hover state.
    func update(_ windows: [TaskWindow]) {
        let sig = windows.map {
            "\($0.key.id)|\($0.displayTitle)|\($0.isVisible)|\($0.isFocused)|\($0.isOnCurrentSpace)|\($0.badge ?? "")"
        }
        guard sig != signature, !isDragging else { return }
        if signature == ["message"] { stack.arrangedSubviews.forEach { $0.removeFromSuperview() } }
        signature = sig

        // Windows of an app stay in one group, placed where its first window is.
        let groups = layout.groupByApp ? Self.grouped(windows) : windows.map { [$0] }

        // Shrink buttons evenly when the bar gets crowded.
        let count = CGFloat(max(groups.count, 1))
        let available = screenFrame.width - 2 * Self.inset - (count - 1) * Self.spacing
        let width = min(maxButtonWidth, floor(available / count))

        let ids = Set(groups.map(buttonID))
        let gone = buttons.filter { !ids.contains($0.key) }
        for (id, button) in gone {
            button.removeFromSuperview()
            buttons[id] = nil
        }
        let kept = stack.arrangedSubviews.compactMap { $0 as? TaskButton }

        var added: [TaskButton] = []
        let ordered = groups.map { tasks -> TaskButton in
            let id = buttonID(tasks)
            if let button = buttons[id] {
                button.tasks = tasks
                return button
            }
            let button = makeButton(tasks)
            buttons[id] = button
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

    /// Per app while grouping, so an app's second window joins its button instead of replacing it.
    private func buttonID(_ tasks: [TaskWindow]) -> String {
        layout.groupByApp ? "app:\(tasks[0].app.processIdentifier)" : tasks[0].key.id
    }

    private static func grouped(_ windows: [TaskWindow]) -> [[TaskWindow]] {
        var groups: [[TaskWindow]] = []
        var index: [pid_t: Int] = [:]
        for w in windows {
            if let i = index[w.app.processIdentifier] {
                groups[i].append(w)
            } else {
                index[w.app.processIdentifier] = groups.count
                groups.append([w])
            }
        }
        return groups
    }

    private func makeButton(_ tasks: [TaskWindow]) -> TaskButton {
        let button = TaskButton(tasks: tasks, width: maxButtonWidth, height: buttonHeight)
        button.target = self
        button.action = #selector(buttonClicked(_:))
        // Filled when it opens (`menuNeedsUpdate`), so app names and screens are current.
        let menu = NSMenu()
        menu.delegate = self
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
        if sender.isGroup {
            showWindows(of: sender)
        } else {
            onClick?(sender.task)
        }
    }

    /// A group's windows as a menu next to its button, opening away from the bar's screen edge.
    private func showWindows(of button: TaskButton) {
        let menu = NSMenu()
        for w in button.tasks {
            var state: [String] = []
            if w.isMinimized {
                state.append("minimized")
            } else if w.isAppHidden {
                state.append("hidden")
            }
            if !w.isOnCurrentSpace { state.append("on another Space") }
            let title = w.displayTitle + (state.isEmpty ? "" : " (\(state.joined(separator: ", ")))")
            let item = add(title, #selector(windowChosen(_:)), to: menu)
            item.state = w.isFocused ? .on : .off
            // A short-lived menu, so holding the window here retains nothing for long.
            item.representedObject = w
        }
        let rect = panel.convertToScreen(button.convert(button.bounds, to: nil))
        let gap: CGFloat = 4
        let top = layout.position == .bottom ? rect.maxY + gap + menu.size.height : rect.minY - gap
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: top), in: nil)
    }

    @objc private func windowChosen(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? TaskWindow else { return }
        onActivate?(w)
    }

    /// Closes a single window; ignored on a group, where it would close several at once.
    fileprivate func middleClicked(_ button: TaskButton) {
        guard !button.isGroup else { return }
        onAction?(button.task, .close)
    }

    /// Moves `button` along the bar while the pointer is dragged; reports the new order on release.
    fileprivate func drag(_ button: TaskButton) {
        isDragging = true
        defer { isDragging = false }
        while let event = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let x = stack.convert(event.locationInWindow, from: nil).x
            let index = stack.arrangedSubviews.filter { $0 !== button && $0.frame.midX < x }.count
            if stack.arrangedSubviews.firstIndex(of: button) != index {
                stack.insertArrangedSubview(button, at: index)
                stack.layoutSubtreeIfNeeded()
            }
            if event.type == .leftMouseUp { break }
        }
        // Updates skipped meanwhile, or a reorder the source can't apply, must not leave the
        // buttons out of step with the windows.
        signature = []
        onReorder?(stack.arrangedSubviews.flatMap { ($0 as? TaskButton)?.tasks ?? [] })
    }

    /// Scrolling down (or right) focuses the next window, up the previous one, wrapping around.
    private func scroll(_ event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        if event.phase == .began { scrollAmount = 0 }
        let delta =
            abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            scrollAmount += delta
            guard abs(scrollAmount) >= Self.scrollStep else { return }
        } else {
            // A mouse wheel: one notch, one window.
            guard delta != 0 else { return }
            scrollAmount = delta
        }
        let forward = scrollAmount < 0
        scrollAmount = 0

        let tasks = stack.arrangedSubviews.flatMap { ($0 as? TaskButton)?.tasks ?? [] }
        guard !tasks.isEmpty else { return }
        let recent = cycled.flatMap { Date().timeIntervalSince($0.at) < Self.cycleMemory ? $0.key : nil }
        let current = tasks.firstIndex { $0.key == recent } ?? tasks.firstIndex(where: \.isFocused)
        let next =
            current.map { (forward ? $0 + 1 : $0 - 1 + tasks.count) % tasks.count } ?? (forward ? 0 : tasks.count - 1)
        cycled = (tasks[next].key, Date())
        onActivate?(tasks[next])
    }
}

extension TaskbarBar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let button = button(for: menu) else { return }
        let task = button.task
        menu.removeAllItems()
        add("New Window", #selector(newWindowClicked(_:)), to: menu)
        menu.addItem(.separator())
        if button.isGroup {
            add("Close All Windows", #selector(closeAllClicked(_:)), to: menu)
            menu.addItem(.separator())
            add("Hide \(task.appName)", #selector(hideClicked(_:)), to: menu)
            add("Quit \(task.appName)", #selector(quitClicked(_:)), to: menu)
            return
        }
        let others = NSScreen.screens.filter { $0.frame != screenFrame }
        if !others.isEmpty {
            let screens = NSMenu()
            for screen in others {
                add(screen.localizedName, #selector(moveClicked(_:)), to: screens).representedObject = screen
            }
            menu.addItem(withTitle: "Move to Screen", action: nil, keyEquivalent: "").submenu = screens
        }
        add("Close Window", #selector(closeClicked(_:)), to: menu)
        menu.addItem(.separator())
        add("Hide \(task.appName)", #selector(hideClicked(_:)), to: menu)
        add("Quit \(task.appName)", #selector(quitClicked(_:)), to: menu)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// The button whose menu (or submenu) this is. Found via the menu: a `representedObject`
    /// pointing back at the button would retain it.
    private func button(for menu: NSMenu?) -> TaskButton? {
        var menu = menu
        while let m = menu {
            if let button = buttons.values.first(where: { $0.menu === m }) { return button }
            menu = m.supermenu
        }
        return nil
    }

    private func perform(_ action: Action, from item: NSMenuItem) {
        guard let task = button(for: item.menu)?.task else { return }
        onAction?(task, action)
    }

    @objc private func newWindowClicked(_ sender: NSMenuItem) { perform(.newWindow, from: sender) }
    @objc private func closeClicked(_ sender: NSMenuItem) { perform(.close, from: sender) }
    @objc private func closeAllClicked(_ sender: NSMenuItem) {
        button(for: sender.menu)?.tasks.forEach { onAction?($0, .close) }
    }
    @objc private func hideClicked(_ sender: NSMenuItem) { perform(.hideApp, from: sender) }
    @objc private func quitClicked(_ sender: NSMenuItem) { perform(.quitApp, from: sender) }

    @objc private func moveClicked(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        perform(.moveTo(screen), from: sender)
    }
}

/// The bar's content view; scroll events over the bar end up here.
private final class BarView: NSView {
    var onScroll: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}

/// A window's button, or with *Group windows by app* an app's button for all its windows on the bar.
final class TaskButton: NSButton {
    /// Never empty. More than one window only while grouping.
    var tasks: [TaskWindow] {
        didSet { configure(oldApp: oldValue[0].app) }
    }
    /// The window the button stands for: the focused one of a group, else its first.
    var task: TaskWindow { tasks.first(where: \.isFocused) ?? tasks[0] }
    var isGroup: Bool { tasks.count > 1 }
    private(set) var widthConstraint: NSLayoutConstraint!
    /// Minimized windows and windows of hidden apps are dimmed; a group once none is visible.
    var targetAlpha: CGFloat { tasks.contains(where: \.isVisible) ? 1 : 0.5 }
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
    private let badge = BadgeView(fill: .systemRed, text: .white)
    /// A group's window count, at the trailing edge.
    private let count = BadgeView(fill: .labelColor.withAlphaComponent(0.15), text: .labelColor)
    /// How far the pointer must move sideways before a press becomes a drag.
    private static let dragThreshold: CGFloat = 4
    /// Space between the count and the button's trailing edge, and between the count and the title.
    private static let countInset: CGFloat = 6

    override class var cellClass: AnyClass? {
        get { TaskButtonCell.self }
        set {}
    }

    init(tasks: [TaskWindow], width: CGFloat, height: CGFloat) {
        precondition(!tasks.isEmpty)
        self.tasks = tasks
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
        addSubview(count)
        NSLayoutConstraint.activate([
            widthConstraint, heightAnchor.constraint(equalToConstant: height),
            // Over the top-right corner of the 18 pt icon.
            badge.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -7),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.countInset),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        configure(oldApp: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Applies `tasks` to the button; called again whenever a window's state changes.
    private func configure(oldApp: NSRunningApplication?) {
        let name =
            isGroup
            ? "\(task.appName), \(tasks.count) windows"
            : task.title.isEmpty ? task.appName : "\(task.appName) — \(task.title)"
        let elsewhere = tasks.allSatisfy { !$0.isOnCurrentSpace }
        title = " " + (isGroup ? task.appName : task.displayTitle)
        toolTip =
            (isGroup ? "\(task.appName) — \(tasks.count) windows" : name) + (elsewhere ? " (on another Space)" : "")
        if oldApp != task.app, let icon = task.app.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 18, height: 18)
            image = icon
        }
        badge.text = task.badge
        count.text = isGroup ? "\(tasks.count)" : nil
        // The title ends before the count instead of running under it.
        (cell as? TaskButtonCell)?.trailingInset = isGroup ? count.fittingSize.width + 2 * Self.countInset : 0
        // VoiceOver reads this instead of the padded title, including what the tint conveys.
        var label = [name]
        if task.isFocused { label.append("focused") }
        if tasks.allSatisfy(\.isMinimized) {
            label.append("minimized")
        } else if task.isAppHidden {
            label.append("hidden")
        }
        if elsewhere { label.append("on another Space") }
        if let badge = task.badge { label.append("badge \(badge)") }
        setAccessibilityLabel(label.joined(separator: ", "))
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Tracks the press itself instead of NSButton's tracking loop: a press that moves sideways
    /// becomes a drag along the bar, a release on the button a click.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        isPressed = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                isPressed = false
                if inside { sendAction(action, to: target) }
                return
            }
            if abs(next.locationInWindow.x - start.x) > Self.dragThreshold {
                isPressed = false
                (target as? TaskbarBar)?.drag(self)
                return
            }
            isPressed = inside
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber != 2 { super.otherMouseDown(with: event) }
    }

    /// Middle click closes the window, as in browsers' tab bars.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return super.otherMouseUp(with: event)
        }
        (target as? TaskbarBar)?.middleClicked(self)
    }

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

/// Leaves room at the trailing edge for a group's count.
private final class TaskButtonCell: NSButtonCell {
    var trailingInset: CGFloat = 0

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        var frame = frame
        frame.size.width = max(0, min(frame.width, controlView.bounds.width - trailingInset - frame.minX))
        return super.drawTitle(title, withFrame: frame, in: controlView)
    }
}

/// A capsule with a short text: the app's Dock badge (unread count and the like) or a group's count.
private final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let fill: NSColor

    var text: String? {
        didSet {
            label.stringValue = text ?? ""
            isHidden = text == nil
        }
    }

    init(fill: NSColor, text: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = text
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
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
