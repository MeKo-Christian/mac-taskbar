import AppKit
import Combine

/// User settings, persisted in `UserDefaults` (domain `io.github.cwbudde.mactaskbar`).
/// Values are clamped on load, so a hand-edited `defaults write` can't break the layout.
@MainActor
final class Settings: ObservableObject {
    enum Position: String, CaseIterable {
        case bottom, top
    }

    static let heightRange: ClosedRange<Double> = 24...48
    static let buttonWidthRange: ClosedRange<Double> = 120...400

    @Published var position: Position { didSet { save(position.rawValue, Key.position) } }
    @Published var barHeight: Double { didSet { save(barHeight, Key.barHeight) } }
    @Published var maxButtonWidth: Double { didSet { save(maxButtonWidth, Key.maxButtonWidth) } }
    /// Display UUIDs of screens without a bar. Stored inverted, so new screens get a bar by default.
    @Published var disabledScreens: Set<String> { didSet { save(disabledScreens.sorted(), Key.disabledScreens) } }

    private enum Key {
        static let position = "barPosition"
        static let barHeight = "barHeight"
        static let maxButtonWidth = "maxButtonWidth"
        static let disabledScreens = "disabledScreens"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        position = defaults.string(forKey: Key.position).flatMap(Position.init) ?? .bottom
        barHeight = Self.load(defaults, Key.barHeight, default: 32, in: Self.heightRange)
        maxButtonWidth = Self.load(defaults, Key.maxButtonWidth, default: 220, in: Self.buttonWidthRange)
        disabledScreens = Set(defaults.stringArray(forKey: Key.disabledScreens) ?? [])
    }

    func isEnabled(_ screen: NSScreen) -> Bool {
        screen.displayUUID.map { !disabledScreens.contains($0) } ?? true
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
