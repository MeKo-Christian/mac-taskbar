import AppKit
import Combine

/// User settings, persisted in `UserDefaults` (domain `io.github.cwbudde.mactaskbar`).
/// Values are clamped on load, so a hand-edited `defaults write` can't break the layout.
@MainActor
final class Settings: ObservableObject {
    enum Position: String, CaseIterable {
        case bottom, top
    }

    /// Which windows the bars list: from every Space, or only from the Spaces the displays show.
    enum SpaceMode: String, CaseIterable {
        case all, current
    }

    static let heightRange: ClosedRange<Double> = 24...48
    static let buttonWidthRange: ClosedRange<Double> = 120...400

    @Published var position: Position { didSet { save(position.rawValue, Key.position) } }
    @Published var barHeight: Double { didSet { save(barHeight, Key.barHeight) } }
    @Published var maxButtonWidth: Double { didSet { save(maxButtonWidth, Key.maxButtonWidth) } }
    /// Display UUIDs of screens without a bar. Stored inverted, so new screens get a bar by default.
    @Published var disabledScreens: Set<String> { didSet { save(disabledScreens.sorted(), Key.disabledScreens) } }
    /// Show a single bar on the screen with the menu bar, overriding `disabledScreens`.
    @Published var menuBarScreenOnly: Bool { didSet { save(menuBarScreenOnly, Key.menuBarScreenOnly) } }
    @Published var spaces: SpaceMode { didSet { save(spaces.rawValue, Key.spaces) } }
    /// Shrink windows that reach under a bar (zoomed, tiled, resized to the edge) to end at its edge.
    @Published var keepWindowsClear: Bool { didSet { save(keepWindowsClear, Key.keepWindowsClear) } }

    private enum Key {
        static let position = "barPosition"
        static let barHeight = "barHeight"
        static let maxButtonWidth = "maxButtonWidth"
        static let disabledScreens = "disabledScreens"
        static let menuBarScreenOnly = "menuBarScreenOnly"
        static let spaces = "spaces"
        static let keepWindowsClear = "keepWindowsClear"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        position = defaults.string(forKey: Key.position).flatMap(Position.init) ?? .bottom
        barHeight = Self.load(defaults, Key.barHeight, default: 32, in: Self.heightRange)
        maxButtonWidth = Self.load(defaults, Key.maxButtonWidth, default: 220, in: Self.buttonWidthRange)
        disabledScreens = Set(defaults.stringArray(forKey: Key.disabledScreens) ?? [])
        menuBarScreenOnly = defaults.bool(forKey: Key.menuBarScreenOnly)
        spaces = defaults.string(forKey: Key.spaces).flatMap(SpaceMode.init) ?? .all
        keepWindowsClear = defaults.object(forKey: Key.keepWindowsClear) as? Bool ?? true
    }

    func isEnabled(_ screen: NSScreen) -> Bool {
        // The first screen is the one with the menu bar (not `NSScreen.main`, which follows focus).
        if menuBarScreenOnly { return screen == NSScreen.screens.first }
        return screen.displayUUID.map { !disabledScreens.contains($0) } ?? true
    }

    func setEnabled(_ enabled: Bool, for screen: NSScreen) {
        guard let id = screen.displayUUID else { return }
        if enabled { disabledScreens.remove(id) } else { disabledScreens.insert(id) }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private static func load(
        _ defaults: UserDefaults, _ key: String, default value: Double, in range: ClosedRange<Double>
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return value }
        return min(max(defaults.double(forKey: key), range.lowerBound), range.upperBound)
    }
}

extension NSScreen {
    /// Stable across reboots and reconnects, unlike `CGDirectDisplayID`.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
