import SwiftUI

/// HTTPS-only IPA download into a temp file. The result is only ever handed to
/// PersonalAppsLibrary.add, which validates the archive. No DRM or protection bypass.
enum PersonalIPAURL {
    static let maximumBytes: Int64 = 512 * 1024 * 1024

    static func validate(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: text), let url = comps.url else {
            throw SideloadError.message(personalText("Enter a valid link.", "اكتب رابط صحيح."))
        }
        guard comps.scheme?.lowercased() == "https" else {
            throw SideloadError.message(personalText("Only https links are allowed.", "بس روابط https مسموحة."))
        }
        try checkHost(url)
        guard url.pathExtension.lowercased() == "ipa" else {
            throw SideloadError.message(personalText("The link must point directly to an .ipa file.", "الرابط لازم يكون مباشر لملف .ipa."))
        }
        return url
    }

    /// Also applied to every redirect target.
    static func checkHost(_ url: URL) throws {
        let bad = SideloadError.message(personalText("This address is not allowed.", "هالعنوان مو مسموح."))
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { throw bad }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { throw bad }
        if host.contains(":") { throw bad } // IPv6 literals are not accepted at all
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, let nums = Optional(parts.compactMap { Int($0) }), nums.count == 4 {
            guard nums.allSatisfy({ (0...255).contains($0) }) else { throw bad }
            let (a, b) = (nums[0], nums[1])
            if a == 0 || a == 10 || a == 127 || a >= 224 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) { throw bad }
        } else if host.allSatisfy({ $0.isNumber || $0 == "." }) || host.hasPrefix("0x") { throw bad }
    }
}

private final class PersonalIPADownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    func attach(_ c: CheckedContinuation<URL, Error>) { continuation = c }

    private func fail(_ message: String, _ task: URLSessionTask) {
        if result == nil { result = .failure(SideloadError.message(message)) }
        task.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, (try? PersonalIPAURL.checkHost(url)) != nil { completionHandler(request) }
        else { fail(personalText("The link redirected to a blocked address.", "الرابط حوّل لعنوان مو مسموح."), task); completionHandler(nil) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > PersonalIPAURL.maximumBytes || totalBytesWritten > PersonalIPAURL.maximumBytes {
            fail(personalText("The file is larger than 512 MB.", "الملف أكبر من 512 ميغا."), downloadTask); return
        }
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard case nil = result else { return }
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            result = .failure(SideloadError.message(personalText("The server did not return the file.", "السيرفر ما رجّع الملف."))); return
        }
        let fm = FileManager.default
        do {
            let size = (try fm.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= PersonalIPAURL.maximumBytes else {
                throw SideloadError.message(personalText("The file is empty or larger than 512 MB.", "الملف فاضي أو أكبر من 512 ميغا."))
            }
            let dir = fm.temporaryDirectory.appendingPathComponent("personal-url-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            let dest = dir.appendingPathComponent("Download.ipa")
            try fm.moveItem(at: location, to: dest)
            result = .success(dest)
        } catch { result = .failure(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        session.finishTasksAndInvalidate()
        if case .failure(let e)? = result { c.resume(throwing: e); return }
        if case .success(let url)? = result {
            if error != nil {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            } else { c.resume(returning: url); return }
        }
        if let error = error as? URLError, error.code == .cancelled {
            c.resume(throwing: CancellationError())
        } else if error != nil {
            c.resume(throwing: SideloadError.message(personalText("Download failed. Check the link and your connection.", "فشل التحميل. تأكد من الرابط والاتصال.")))
        } else {
            c.resume(throwing: SideloadError.message(personalText("Download failed.", "فشل التحميل.")))
        }
    }
}

@MainActor
final class PersonalIPADownloader: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var received: Int64 = 0
    @Published private(set) var total: Int64 = 0
    private var task: URLSessionDownloadTask?

    var fraction: Double? { total > 0 ? min(1, Double(received) / Double(total)) : nil }

    /// Returns a temp file; the caller must delete its folder.
    func download(_ raw: String) async throws -> URL {
        guard !active else { throw SideloadError.message(personalText("A download is already running.", "في تحميل شغّال.")) }
        let url = try PersonalIPAURL.validate(raw)
        active = true; received = 0; total = 0
        defer { active = false; task = nil }
        let delegate = PersonalIPADownload()
        delegate.onProgress = { [weak self] done, all in
            Task { @MainActor in self?.received = done; self?.total = max(all, 0) }
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("Mirsa", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        self.task = task
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                delegate.attach(c)
                task.resume()
            }
        } onCancel: { task.cancel() }
    }
    func cancel() { task?.cancel() }
}

struct PersonalURLImportSheet: View {
    /// Receives the downloaded temp IPA. The sheet deletes the temp file afterwards,
    /// so the receiver must copy what it needs (both importers copy).
    var disabled = false
    let onFile: (URL) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloader = PersonalIPADownloader()
    @State private var link = ""
    @State private var message: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                VStack(alignment: .leading, spacing: 16) {
                    Text(personalText("Import from link", "استيراد من رابط")).font(.title2.bold())
                    Text(personalText("Paste a direct https link to an .ipa file. The app is checked before it is added; nothing is installed.",
                                      "الصق رابط https مباشر لملف .ipa. التطبيق بينفحص قبل ما ينضاف، وما بينثبت شي."))
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("https://example.com/app.ipa", text: $link)
                        .keyboardType(.URL).textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .padding(14).appsGlass(cornerRadius: 16).disabled(working)
                    if working {
                        VStack(alignment: .leading, spacing: 8) {
                            if let f = downloader.fraction { ProgressView(value: f) } else { ProgressView() }
                            Text(progressText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.red.opacity(0.9)) }
                    HStack {
                        if working {
                            Button(role: .destructive) { downloader.cancel() } label: {
                                Label(personalText("Cancel", "إلغاء"), systemImage: "xmark.circle")
                            }
                        }
                        Spacer()
                        Button { start() } label: {
                            Label(personalText("Download", "تحميل"), systemImage: "arrow.down.circle.fill").fontWeight(.semibold)
                        }.buttonStyle(.borderedProminent)
                            .disabled(working || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || disabled)
                    }
                    Spacer()
                }.padding(20)
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) {
                Button(personalText("Back", "رجوع")) { downloader.cancel(); dismiss() }
            } }
        }
        .preferredColorScheme(.dark).environment(\.layoutDirection, .leftToRight)
        .interactiveDismissDisabled(working)
    }
    private var progressText: String {
        let f = ByteCountFormatter(); f.countStyle = .file
        if downloader.total > 0 { return f.string(fromByteCount: downloader.received) + " / " + f.string(fromByteCount: downloader.total) }
        return f.string(fromByteCount: downloader.received)
    }
    private func start() {
        message = nil; working = true
        Task {
            var file: URL?
            let operation = UUID()
            do {
                let temp = try await downloader.download(link)
                file = temp
                try Task.checkCancellation()
                try await onFile(temp)
                MirsaCompletionFeedback.shared.finish(operationID: operation, outcome: .success)
                try? FileManager.default.removeItem(at: temp.deletingLastPathComponent())
                dismiss()
            } catch is CancellationError {
                message = personalText("Download cancelled.", "انلغى التحميل.")
            } catch {
                MirsaCompletionFeedback.shared.finish(operationID: operation, outcome: MirsaCompletionFeedback.outcome(for: error))
                message = error.localizedDescription
            }
            if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            working = false
        }
    }
}
