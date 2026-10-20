import Foundation
import OSLog

enum PolishUserErrorMessage {
    private static let logger = Logger(subsystem: "Blackmaks.NaviAstras.pl", category: "UserFacingErrors")

    static func make(_ error: Error, fallback: String) -> String {
        logger.error("\(fallback, privacy: .public): \(error.localizedDescription, privacy: .private)")
        return fallback
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? CocoaError)?.code == .userCancelled
            || (error as? URLError)?.code == .cancelled
    }
}
