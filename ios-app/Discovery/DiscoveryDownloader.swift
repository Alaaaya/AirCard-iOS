import Foundation
#if canImport(AirliftFFI)
import AirliftFFI
#endif

/// Shared by candidate verification AND the accepted-card download path.
/// Rust reqwest pins the vetted DNS addresses for each socket, retains the
/// original hostname for TLS/SNI and manually revalidates every redirect.
/// There is deliberately no URLSession fallback.
final class DiscoveryDownloader {
    struct Limits { var maxBytes: Int64 = 3 * 1024 * 1024 * 1024; var maxRedirects = 5; var requestTimeout: TimeInterval = 30; var totalTimeout: TimeInterval = 1800 }

    enum Failure: Error, LocalizedError, Equatable {
        case unsafe(String), http(Int), htmlPage, tooBig, tooManyRedirects, cancelled, network(String)
        var errorDescription: String? {
            switch self {
            case .unsafe(let s): return s
            case .http(let c) where c == 403: return "The host refused the download (403). The link may have expired or needs a login."
            case .http(let c) where c == 404 || c == 410: return "The file is gone (\(c))."
            case .http(let c): return "The host answered \(c)."
            case .htmlPage: return "The link opened a web page instead of an IPA (captcha, login or expired link)."
            case .tooBig: return "The file is bigger than the allowed limit."
            case .tooManyRedirects: return "Too many redirects."
            case .cancelled: return "Cancelled."
            case .network(let s): return s
            }
        }
    }


    private let limits: Limits
    #if canImport(AirliftFFI)
    private final class Cancellation: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer?
        init() { pointer = al_discovery_cancel_new() }
        deinit { al_discovery_cancel_free(pointer) }
        func cancel() { al_discovery_cancel(pointer) }
    }
    private let cancellation = Cancellation()
    #endif

    init(limits: Limits = Limits()) { self.limits = limits }

    func cancel() {
        #if canImport(AirliftFFI)
        cancellation.cancel()
        #endif
    }

    func download(_ url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        if let v = DiscoveryURLPolicy.check(url) { throw Failure.unsafe(v.description) }
        #if canImport(AirliftFFI)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-\(UUID().uuidString).ipa")
        let token = cancellation
        let maxBytes = UInt64(max(0, limits.maxBytes))
        let seconds = UInt64(max(1, min(1800, limits.totalTimeout)))
        let source = url.absoluteString
        progress(0)
        return try await withTaskCancellationHandler(operation: {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                // Dedicated GCD worker, not a Tokio thread or a MainActor task.
                DispatchQueue.global(qos: .utility).async {
                    let error = source.withCString { sourcePtr in
                        dest.path.withCString { destPtr in
                            al_discovery_download(sourcePtr, destPtr, maxBytes, seconds, token.pointer)
                        }
                    }
                    if let error {
                        let message = String(cString: error)
                        al_string_free(error)
                        try? FileManager.default.removeItem(at: dest)
                        continuation.resume(throwing: Failure.network(message))
                        return
                    }
                    do {
                        // Bytes must describe an actual bounded IPA, even when
                        // a caller forgets to run the richer identity check.
                        var archiveLimits = IPALimits()
                        archiveLimits.maxFileSize = maxBytes
                        _ = try IPAValidator.validate(file: dest, expectedBundleID: nil,
                            expectedVersion: nil, deviceOS: nil, limits: archiveLimits)
                        continuation.resume(returning: dest)
                    } catch {
                        try? FileManager.default.removeItem(at: dest)
                        continuation.resume(throwing: error)
                    }
                }
            }
            progress(1)
            return result
        }, onCancel: { token.cancel() })
        #else
        // Pure Swift policy-test builds have no Rust transport. Never silently
        // restore the vulnerable unpinned URLSession path.
        throw Failure.unsafe("Pinned download transport is unavailable.")
        #endif
    }
}
