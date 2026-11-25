import Foundation
import os

/// Logging through `os.Logger` (subsystem `com.alphapengwang.rolltop`). When the environment
/// has `ROLLTOP_LOG_STDERR=1` (set by `scripts/dev-install.sh --shell`), every line is
/// echoed to stderr as well. Messages are logged as public: they never contain user data.
///
///     private let log = Log.logger("reveal")
///     log.info("hover reveal armed")
nonisolated enum Log {
    static let subsystem = "com.alphapengwang.rolltop"
    static let echoToStderr = ProcessInfo.processInfo.environment["ROLLTOP_LOG_STDERR"] == "1"

    static func logger(_ category: String) -> RolltopLogger { RolltopLogger(category: category) }
}

nonisolated struct RolltopLogger: Sendable {
    let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: Log.subsystem, category: category)
    }

    func debug(_ message: String) { emit(.debug, message) }
    func info(_ message: String) { emit(.info, message) }
    func notice(_ message: String) { emit(.default, message) }
    func error(_ message: String) { emit(.error, message) }

    private func emit(_ type: OSLogType, _ message: String) {
        logger.log(level: type, "\(message, privacy: .public)")
        guard Log.echoToStderr else { return }
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))
        FileHandle.standardError.write(Data("\(stamp) [\(category)] \(message)\n".utf8))
    }
}
