import Foundation
import OSLog

public struct Diagnostics: Sendable {
    private let logger: Logger

    public init(subsystem: String = Bundle.main.bundleIdentifier ?? "dev.ax.macstt.swift") {
        self.logger = Logger(subsystem: subsystem, category: "runtime")
    }

    public func lifecycle(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func failure(code: String, stage: String, detail: String? = nil) {
        if let detail {
            logger.error("failure code=\(code, privacy: .public) stage=\(stage, privacy: .public) detail=\(detail, privacy: .private(mask: .hash))")
        } else {
            logger.error("failure code=\(code, privacy: .public) stage=\(stage, privacy: .public)")
        }
    }
}
