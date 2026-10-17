import Foundation
import os

/// Unified logging (replaces the ad-hoc /tmp log files).
///
/// Read with:
///   log stream --level info --predicate 'subsystem == "com.blackhole.monitor"'
///
/// Never call from an audio render callback.
struct Log {
    static let app = Log(category: "app")
    static let audio = Log(category: "audio")
    static let demucs = Log(category: "demucs")

    private let logger: Logger

    private init(category: String) {
        logger = Logger(subsystem: "com.blackhole.monitor", category: category)
    }

    func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
