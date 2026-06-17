import OSLog

enum AppLogger {
    static let subsystem = "com.ryukeilee.CodexMonitorNativePrototype"

    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    static let statusBar = Logger(subsystem: subsystem, category: "StatusBar")
    static let popover = Logger(subsystem: subsystem, category: "Popover")
    static let refresh = Logger(subsystem: subsystem, category: "Refresh")
    static let snapshot = Logger(subsystem: subsystem, category: "Snapshot")
    static let system = Logger(subsystem: subsystem, category: "System")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
}
