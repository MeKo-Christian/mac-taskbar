import os

/// View with: log stream --level debug --predicate 'subsystem == "io.github.cwbudde.mactaskbar"'
enum Log {
    private static let subsystem = "io.github.cwbudde.mactaskbar"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let ax = Logger(subsystem: subsystem, category: "ax")
    static let events = Logger(subsystem: subsystem, category: "events")
}
