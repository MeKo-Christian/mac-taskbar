import AppKit
import ScreenCaptureKit

/// Thumbnails of a button's windows, shown above the button while the pointer rests on it (setting
/// *Show window previews on hover*). Each showing captures the windows once with ScreenCaptureKit,
/// which needs the Screen Recording permission; nothing is captured while no preview shows.
@MainActor
final class WindowPreview {
    /// Whether MacTaskbar may capture windows. Bars check it when they are built, so a grant given
    /// while MacTaskbar runs applies after a relaunch (the Settings footnote says so).
    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    private static let showDelay: TimeInterval = 0.4
    /// Long enough to cross the gap between the button and the preview.
    private static let hideDelay: TimeInterval = 0.25
    private static let thumbnail = CGSize(width: 200, height: 125)
    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 4
    /// Distance kept from the screen's sides.
    private static let margin: CGFloat = 8

    /// A thumbnail was clicked.
    var onActivate: ((TaskWindow) -> Void)?
    /// The button the preview shows (or is about to show) the windows of.
    private(set) weak var button: TaskButton?
    var isShown: Bool { panel.isVisible }

    private let position: Settings.Position
    private let panel: NSPanel
    private let content = PreviewView()
    private let row = NSStackView()
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var capture: Task<Void, Never>?
    private var overButton = false
    private var overPanel = false
    /// The windows the shown cells were built from; a change rebuilds them.
    private var shownSignature: [String] = []

    init(position: Settings.Position) {
        self.position = position
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setAccessibilityTitle("Window previews")

        content.material = .popover
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        content.onHover = { [weak self] inside in
            self?.overPanel = inside
            inside ? self?.cancelHide() : self?.hideSoon()
        }
        panel.contentView = content

        row.orientation = .horizontal
        row.spacing = Self.spacing
        row.edgeInsets = NSEdgeInsets(
            top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
        ])
    }

    /// The pointer entered `button`: show its windows after a moment, or at once while a preview
    /// is already up, so moving along the bar switches previews without waiting.
    func pointerEntered(_ button: TaskButton) {
        overButton = true
        cancelHide()
        showTimer?.invalidate()
        if isShown {
            show(button)
        } else {
            self.button = button
            showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let button = self.button else { return }
                    self.showTimer = nil
                    self.show(button)
                }
            }
        }
    }

    func pointerExited(_ button: TaskButton) {
        guard button === self.button else { return }
        overButton = false
        showTimer?.invalidate()
        showTimer = nil
        hideSoon()
    }

    /// The bar's buttons changed: follow the shown button's windows, or go when it is gone.
    func buttonsChanged() {
        guard isShown, let button else { return }
        if button.superview == nil {
            hide()
        } else if Self.signature(button.tasks) != shownSignature {
            show(button)
        }
    }

    func hide() {
        showTimer?.invalidate()
        showTimer = nil
        cancelHide()
        capture?.cancel()
        capture = nil
        overPanel = false
        shownSignature = []
        panel.orderOut(nil)
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    private func hideSoon() {
        guard !overButton, !overPanel, hideTimer == nil, isShown else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.hideDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideTimer = nil
                if !self.overButton && !self.overPanel { self.hide() }
            }
        }
    }

    private func cancelHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private static func signature(_ tasks: [TaskWindow]) -> [String] {
        tasks.map { "\($0.key.id)|\($0.displayTitle)|\($0.isFocused)|\($0.isVisible)" }
    }

    /// Shows the cells straight away with app icons; the thumbnails replace them as they arrive.
    private func show(_ button: TaskButton) {
        guard let barWindow = button.window, let screen = barWindow.screen else { return }
        self.button = button
        capture?.cancel()
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let tasks = button.tasks
        shownSignature = Self.signature(tasks)

        // Shrink the cells evenly when a group's row would not fit on the screen.
        let available = screen.frame.width - 2 * Self.margin - 2 * Self.padding
        let natural = CGFloat(tasks.count) * Self.thumbnail.width + CGFloat(tasks.count - 1) * Self.spacing
        let scale = min(1, available / natural)
        let size = CGSize(width: floor(Self.thumbnail.width * scale), height: floor(Self.thumbnail.height * scale))
        let cells = tasks.map { w in
            let cell = PreviewCell(task: w, size: size)
            cell.onClick = { [weak self] in
                self?.hide()
                self?.onActivate?(w)
            }
            row.addArrangedSubview(cell)
            return cell
        }

        row.layoutSubtreeIfNeeded()
        let fitting = row.fittingSize
        let anchor = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let x = min(
            max(anchor.midX - fitting.width / 2, screen.frame.minX + Self.margin),
            screen.frame.maxX - Self.margin - fitting.width)
        let y = position == .bottom ? anchor.maxY + Self.gap : anchor.minY - Self.gap - fitting.height
        panel.setFrame(CGRect(x: x, y: y, width: fitting.width, height: fitting.height), display: true)
        panel.orderFrontRegardless()
        panel.invalidateShadow()

        let scaleFactor = screen.backingScaleFactor
        capture = Task { [weak self] in
            guard Self.isAllowed,
                let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            else { return }
            for cell in cells {
                guard !Task.isCancelled, self != nil else { return }
                if let image = await Self.image(of: cell.task, in: content, fitting: size, scale: scaleFactor) {
                    cell.image = image
                }
            }
        }
        Log.app.debug("Preview: \(tasks.map(\.key.id).joined(separator: " "), privacy: .public)")
    }

    /// One capture of the window, aspect-fit into `size`. Nil when ScreenCaptureKit doesn't list
    /// the window or can't capture it.
    private static func image(
        of w: TaskWindow, in content: SCShareableContent, fitting size: CGSize, scale: CGFloat
    ) async -> CGImage? {
        guard let id = w.windowID, let window = content.windows.first(where: { $0.windowID == id }),
            window.frame.width > 0, window.frame.height > 0
        else { return nil }
        let fit = min(size.width / window.frame.width, size.height / window.frame.height)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(window.frame.width * fit * scale))
        config.height = max(1, Int(window.frame.height * fit * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            Log.app.debug("Preview: no capture of \(id): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// The preview's background; reports the pointer entering and leaving it.
private final class PreviewView: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// One window in the preview: its title above its thumbnail (its app's icon until the capture
/// arrives, or when there is none). Clicking it focuses the window.
private final class PreviewCell: NSView {
    let task: TaskWindow
    var onClick: (() -> Void)?
    var image: CGImage? {
        didSet {
            guard let image else { return }
            imageView.image = NSImage(cgImage: image, size: .zero)
        }
    }

    private let imageView = NSImageView()
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private static let inset: CGFloat = 6

    init(task: TaskWindow, size: CGSize) {
        self.task = task
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: task.displayTitle)
        title.font = .systemFont(ofSize: 11)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setAccessibilityElement(false)
        // A large icon stands in for windows without a thumbnail.
        imageView.image = task.app.icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setAccessibilityElement(false)
        addSubview(title)
        addSubview(imageView)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            imageView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
            imageView.widthAnchor.constraint(equalToConstant: size.width),
            imageView.heightAnchor.constraint(equalToConstant: size.height),
        ])
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(task.isFocused ? "\(task.displayTitle), focused" : task.displayTitle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    /// The cell takes the clicks and is the accessibility element under the pointer; its image view
    /// would answer accessibility hit tests otherwise, though it is no element itself.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) != nil ? self : nil }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    /// Tinted like the bar's buttons: the focused window in the accent colour.
    override func draw(_ dirtyRect: NSRect) {
        let strength: CGFloat = isHovered ? 1 : 0
        let tint: NSColor =
            task.isFocused
            ? .controlAccentColor.withAlphaComponent(0.25 + 0.1 * strength)
            : .labelColor.withAlphaComponent(0.1 * strength)
        tint.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
