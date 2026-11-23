import os

/// The app's log categories, under one subsystem.
nonisolated enum LogContext: String {
    case deletion = "🗑️deletion"

    private static let subsystem = "com.kraigspear.XcodeSweep"

    var logger: os.Logger {
        os.Logger(subsystem: LogContext.subsystem, category: rawValue)
    }
}
