import CoreGraphics
import Foundation

/// The Spaces of each display and of each window, through private SkyLight functions (as used by
/// AltTab and yabai). Resolved at runtime: if a macOS update drops one, the bar falls back to the
/// current Space instead of failing to launch.
enum Spaces {
    struct Snapshot: Sendable {
        /// The Space each display shows.
        let current: Set<UInt64>
        /// Every desktop and full-screen Space of every display.
        let all: Set<UInt64>

        static let none = Snapshot(current: [], all: [])
    }

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private struct API {
        let connection: Int32
        let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
        let copySpacesForWindows: CopySpacesForWindows
    }

    private static let api: API? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let connection = dlsym(handle, "SLSMainConnectionID"),
            let displaySpaces = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
            let windowSpaces = dlsym(handle, "SLSCopySpacesForWindows")
        else {
            Log.ax.error("SkyLight Space functions not found; showing the current Space only")
            return nil
        }
        return API(
            connection: unsafeBitCast(connection, to: MainConnectionID.self)(),
            copyManagedDisplaySpaces: unsafeBitCast(displaySpaces, to: CopyManagedDisplaySpaces.self),
            copySpacesForWindows: unsafeBitCast(windowSpaces, to: CopySpacesForWindows.self))
    }()

    static var isAvailable: Bool { api != nil }

    static func snapshot() -> Snapshot {
        guard let api,
            let displays = api.copyManagedDisplaySpaces(api.connection)?.takeRetainedValue() as? [[String: Any]]
        else { return .none }
        var current: Set<UInt64> = []
        var all: Set<UInt64> = []
        for display in displays {
            if let id = (display["Current Space"] as? [String: Any])?["id64"] as? NSNumber {
                current.insert(id.uint64Value)
            }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if let id = space["id64"] as? NSNumber { all.insert(id.uint64Value) }
            }
        }
        return Snapshot(current: current, all: all)
    }

    /// The Spaces a window is on: several for a window assigned to all desktops, none for windows
    /// that are never shown (many apps keep such helper windows at the normal window level).
    static func spaces(of window: CGWindowID) -> Set<UInt64> {
        guard let api,
            let ids = api.copySpacesForWindows(api.connection, allSpacesMask, [window] as CFArray)?
                .takeRetainedValue() as? [NSNumber]
        else { return [] }
        return Set(ids.map(\.uint64Value))
    }

    /// Current, other and full-screen Spaces.
    private static let allSpacesMask: Int32 = 0x7
}
