import Foundation

/// Bounded IPA download. HTTPS policy on the first URL and every redirect hop,
/// capped size, capped time, HTML/CAPTCHA/expiry pages reported explicitly.
final class DiscoveryDownloader: NSObject, URLSessionDownloadDelegate {
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
    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private var redirects = 0
    private var failure: Failure?
    private var progressHandler: ((Double) -> Void)?
    private var task: URLSessionDownloadTask?

    init(limits: Limits = Limits()) {
        self.limits = limits
        super.init()
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = limits.requestTimeout
        c.timeoutIntervalForResource = limits.totalTimeout
        c.httpCookieStorage = nil
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    func cancel() { failure = .cancelled; task?.cancel() }

    func download(_ url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        if let v = DiscoveryURLPolicy.check(url) { throw Failure.unsafe(v.description) }
        guard await DiscoveryDNSPolicy.permits(url) else { throw Failure.unsafe("Non-public DNS destination refused.") }
        progressHandler = progress
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let t = session.downloadTask(with: url)
            task = t
            t.resume()
        }
    }

    private func finish(_ r: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        session.finishTasksAndInvalidate()
        c.resume(with: r)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        if redirects > limits.maxRedirects { failure = .tooManyRedirects; task.cancel(); completionHandler(nil); return }
        guard let target = request.url else { failure = .unsafe("Missing redirect URL."); task.cancel(); completionHandler(nil); return }
        if let v = DiscoveryURLPolicy.check(target) { failure = .unsafe("Redirect refused: " + v.description); task.cancel(); completionHandler(nil); return }
        Task {
            guard await DiscoveryDNSPolicy.permits(target) else {
                failure = .unsafe("Redirect to a non-public DNS destination refused.")
                task.cancel(); completionHandler(nil); return
            }
            completionHandler(request)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limits.maxBytes || totalBytesExpectedToWrite > limits.maxBytes { failure = .tooBig; downloadTask.cancel(); return }
        if totalBytesExpectedToWrite > 0 { progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let h = downloadTask.response as? HTTPURLResponse {
            if !(200..<300).contains(h.statusCode) { failure = .http(h.statusCode); return }
            let ct = (h.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if ct.contains("text/html") { failure = .htmlPage; return }
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-\(UUID().uuidString).ipa")
        do { try FileManager.default.moveItem(at: location, to: dest); finish(.success(dest)) }
        catch { failure = .network(error.localizedDescription) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let f = failure { finish(.failure(f)); return }
        if let error { finish(.failure(Failure.network(error.localizedDescription))); return }
        // success path already resumed in didFinishDownloadingTo
        finish(.failure(Failure.network("No file received.")))
    }
}
