import Foundation
import UIKit
import UserNotifications

/// One stable session per signed bundle. iOS owns the transfer while suspended.
/// After an OS relaunch, completed IPAs remain in Documents/Download Inbox.
@MainActor
final class BackgroundIPADownloads: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundIPADownloads()
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "com.alaa.mirsa") + ".ipa-downloads" }
    var backgroundCompletion: (() -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: ((Int64, Int64) -> Void)?
    private var activeID: Int?
    private var destinations: [Int: URL] = [:]
    private var cancelled = Set<Int>()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    func reconnect() { _ = session }

    func download(_ url: URL, progress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        try Task.checkCancellation()
        guard continuation == nil else { throw URLError(.cannotLoadFromNetwork) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let task = session.downloadTask(with: url)
        activeID = task.taskIdentifier
        self.progress = progress
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { self.cancel(task.taskIdentifier) }
                else { task.resume() }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(task.taskIdentifier) }
        }
    }

    private func cancel(_ id: Int) {
        cancelled.insert(id)
        session.getAllTasks { tasks in
            for task in tasks where task.taskIdentifier == id { task.cancel() }
        }
        if let file = destinations.removeValue(forKey: id) { try? FileManager.default.removeItem(at: file) }
        if activeID == id {
            let pending = continuation
            continuation = nil; activeID = nil; progress = nil
            pending?.resume(throwing: CancellationError())
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard self.activeID == downloadTask.taskIdentifier else { return }
            self.progress?(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        // This temporary URL ceases to exist after the delegate callback returns.
        let fm = FileManager.default
        let folder = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Download Inbox", isDirectory: true)
        let file = folder.appendingPathComponent("Mirsa-\(UUID().uuidString).ipa")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: file)
            Task { @MainActor in
                if self.cancelled.contains(downloadTask.taskIdentifier) { try? fm.removeItem(at: file) }
                else { self.destinations[downloadTask.taskIdentifier] = file }
            }
        } catch {
            Task { @MainActor in self.finish(downloadTask, result: .failure(error)) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error { self.finish(task, result: .failure(error)) }
            else if let file = self.destinations.removeValue(forKey: task.taskIdentifier) {
                if let h = task.response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                    try? FileManager.default.removeItem(at: file)
                    self.finish(task, result: .failure(URLError(.badServerResponse)))
                } else { self.finish(task, result: .success(file)) }
            }
        }
    }

    private func finish(_ task: URLSessionTask, result: Result<URL, Error>) {
        let wasCancelled = cancelled.remove(task.taskIdentifier) != nil
        if wasCancelled {
            if case .success(let file) = result { try? FileManager.default.removeItem(at: file) }
            return
        }
        let pending = activeID == task.taskIdentifier ? continuation : nil
        if activeID == task.taskIdentifier { continuation = nil; activeID = nil; progress = nil }
        let content = UNMutableNotificationContent()
        content.title = "Mirsa"
        switch result {
        case .success:
            content.body = pending == nil
                ? tr("Download finished. Your IPA is in Files › Mirsa › Download Inbox.", "خلص التنزيل. ملف IPA موجود بالملفات › Mirsa › Download Inbox.")
                : tr("Download finished. Open Mirsa to continue installation.", "خلص التنزيل. افتح Mirsa لتكمّل التثبيت.")
        case .failure:
            content.body = tr("Download failed. Open Mirsa and try again.", "فشل التنزيل. افتح Mirsa وجرّب كمان مرة.")
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "mirsa.download.\(task.taskIdentifier)", content: content, trigger: nil))
        pending?.resume(with: result)
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let completion = self.backgroundCompletion
            self.backgroundCompletion = nil
            completion?()
        }
    }
}

final class MirsaDownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundIPADownloads.identifier else { completionHandler(); return }
        BackgroundIPADownloads.shared.backgroundCompletion = completionHandler
        BackgroundIPADownloads.shared.reconnect()
    }
}
