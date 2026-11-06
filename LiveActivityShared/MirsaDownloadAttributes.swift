import ActivityKit
import Foundation

/// Compiled into both targets. Never include URLs, credentials or local paths.
struct MirsaDownloadAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case downloading, preparing, ready, signing, installing, completed, failed, cancelled
    }

    struct ContentState: Codable, Hashable {
        var title: String
        var phase: Phase
        var progress: Double?
        var receivedBytes: Int64
        var expectedBytes: Int64
        var isArabic: Bool
    }

    let operationID: String
}
