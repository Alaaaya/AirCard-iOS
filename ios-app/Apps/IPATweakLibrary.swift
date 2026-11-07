import Foundation
import SwiftUI

struct IPATweak: Identifiable, Codable {
    let id: UUID
    let name: String
    let roots: [String] // paths relative to this item's private directory
    let addedAt: Date
    let packageOnlyCode: Bool
}

/// User-supplied code is stored inertly until explicitly selected in the editor.
/// No package scripts, system installation or automatic third-party downloads.
@MainActor
final class IPATweakLibrary: ObservableObject {
    static let shared = IPATweakLibrary()
    @Published private(set) var items: [IPATweak] = []
    @Published var importing = false

    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MirsaTweakLibrary", isDirectory: true)
    }
    private init() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.root.appendingPathComponent("index.json")),
           let saved = try? JSONDecoder().decode([IPATweak].self, from: data) {
            // Persisted index is not a source of arbitrary absolute paths.
            items = saved.filter { item in
                item.roots.allSatisfy { Self.safeRelative($0) } &&
                item.roots.allSatisfy { FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(item.id.uuidString).appendingPathComponent($0).path) }
            }
        }
    }
    nonisolated private static func safeRelative(_ p: String) -> Bool {
        !p.isEmpty && !p.hasPrefix("/") && !p.contains("\\") && !p.contains("\0") &&
        !p.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
    private func save() throws {
        try JSONEncoder().encode(items).write(to: Self.root.appendingPathComponent("index.json"), options: .atomic)
    }
    func delete(_ item: IPATweak) throws {
        let previous = items
        items.removeAll { $0.id == item.id }
        do { try save() } catch { items = previous; throw error }
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(item.id.uuidString))
    }
    /// Stable per-component id: package UUID + normalized root-relative path.
    static func componentID(_ item: IPATweak, _ root: String) -> String { item.id.uuidString + ":" + root }
    /// Like urls(for:) but skips components the user excluded; order of roots is kept.
    func urls(for id: UUID, excluding excluded: Set<String>) throws -> [URL] {
        guard let item = items.first(where: { $0.id == id }) else {
            throw SideloadError.message("A selected tweak is missing. Select it again.")
        }
        return item.roots.filter { !excluded.contains(Self.componentID(item, $0)) }.map {
            Self.root.appendingPathComponent(item.id.uuidString).appendingPathComponent($0)
        }
    }
    func urls(for ids: Set<UUID>) throws -> [URL] {
        guard ids.isSubset(of: Set(items.map(\.id))) else {
            throw SideloadError.message("A selected tweak is missing. Select it again.")
        }
        return items.filter { ids.contains($0.id) }.flatMap { item in
            item.roots.map { Self.root.appendingPathComponent(item.id.uuidString).appendingPathComponent($0) }
        }
    }

    func addFile(_ url: URL) async throws {
        guard !importing else { throw SideloadError.message("Wait for the current library import.") }
        importing = true
        defer { importing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let item = try await Task.detached { try Self.importFile(url) }.value
        items.insert(item, at: 0)
        do { try save() } catch {
            items.removeAll { $0.id == item.id }
            try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(item.id.uuidString))
            throw error
        }
    }

    func addURL(_ string: String) async throws {
        guard !importing else { throw SideloadError.message("Wait for the current library import.") }
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              ["dylib", "deb"].contains(url.pathExtension.lowercased()) else {
            throw SideloadError.message("Enter a direct HTTPS URL ending in .dylib or .deb. Import .framework folders from Files.")
        }
        importing = true
        defer { importing = false }
        let temporary = try await IPATweakDownload.fetch(url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tweak-url-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let named = folder.appendingPathComponent("Imported." + url.pathExtension.lowercased())
        try FileManager.default.moveItem(at: temporary, to: named)
        let item = try await Task.detached { try Self.importFile(named) }.value
        items.insert(item, at: 0)
        do { try save() } catch {
            items.removeAll { $0.id == item.id }
            try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(item.id.uuidString))
            throw error
        }
    }

    nonisolated private static func copyValidated(_ source: URL, to dest: URL) throws {
        let fm = FileManager.default
        var count = 0
        var bytes: Int64 = 0
        func check(_ url: URL) throws {
            count += 1
            guard url.pathComponents.count - source.pathComponents.count <= 64 else {
                throw SideloadError.message("Framework folder tree is too deep.")
            }
            let v = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard count <= 20_000, v.isSymbolicLink != true, v.isRegularFile == true || v.isDirectory == true else {
                throw SideloadError.message("Framework links, special files or excessive file counts are unsupported.")
            }
            if v.isRegularFile == true {
                bytes += Int64(v.fileSize ?? 0)
                guard bytes <= IPAEditorService.maximumFileSize else { throw SideloadError.message("Tweak exceeds 512 MiB.") }
            }
        }
        try check(source)
        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey])
        if source.hasDirectoryPath || sourceValues.isDirectory == true {
            guard let e = fm.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else {
                throw SideloadError.message("Cannot inspect framework.")
            }
            while let url = e.nextObject() as? URL { try check(url) }
        }
        try fm.copyItem(at: source, to: dest)
    }

    nonisolated private static func importFile(_ source: URL) throws -> IPATweak {
        let fm = FileManager.default
        let type = source.pathExtension.lowercased()
        guard ["dylib", "deb", "framework"].contains(type) else {
            throw SideloadError.message("Supported imports are .dylib, .deb and .framework folders.")
        }
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var roots: [String] = []
            if type == "deb" {
                let package = folder.appendingPathComponent("package.deb")
                try copyValidated(source, to: package)
                let extracted = folder.appendingPathComponent("data", isDirectory: true)
                try IPAEditorService.run("deb", input: package, output: extracted)
                try fm.removeItem(at: package)
                guard let e = fm.enumerator(at: extracted, includingPropertiesForKeys: [.isDirectoryKey]) else {
                    throw SideloadError.message("Could not inspect Debian archive.")
                }
                while let url = e.nextObject() as? URL {
                    if url.pathExtension == "framework", (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                        roots.append("data/" + String(url.path.dropFirst(extracted.path.count + 1)))
                        e.skipDescendants()
                    } else if url.pathExtension == "dylib" {
                        roots.append("data/" + String(url.path.dropFirst(extracted.path.count + 1)))
                    }
                }
                guard !roots.isEmpty else { throw SideloadError.message("This package contains no dylib or framework. Scripts are never run.") }
            } else {
                let name = source.lastPathComponent
                guard safeRelative(name), !name.contains("/") else { throw SideloadError.message("Invalid tweak filename.") }
                let target = folder.appendingPathComponent(name, isDirectory: type == "framework")
                try copyValidated(source, to: target)
                roots = [name]
            }
            return IPATweak(id: id, name: source.deletingPathExtension().lastPathComponent,
                            roots: roots.sorted(), addedAt: Date(), packageOnlyCode: type == "deb")
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }
}


/// Download tasks stream to disk. The delegate cancels oversized responses
/// during transfer instead of discovering a full-disk download afterwards.
private final class IPATweakDownload: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var received: URL?
    private var downloadFailure: Error?
    private var session: URLSession?

    static func fetch(_ url: URL) async throws -> URL {
        let delegate = IPATweakDownload()
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 180
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
            delegate.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https", request.url?.user == nil, request.url?.password == nil else {
            downloadFailure = SideloadError.message("Only HTTPS tweak redirects are allowed.")
            completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > IPAEditorService.maximumFileSize || totalBytesExpectedToWrite > IPAEditorService.maximumFileSize {
            downloadFailure = SideloadError.message("Tweak exceeds 512 MiB.")
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let http = downloadTask.response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  http.url?.scheme?.lowercased() == "https" else {
                throw SideloadError.message("The tweak URL did not return a successful HTTPS download.")
            }
            let size = (try location.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= IPAEditorService.maximumFileSize else { throw SideloadError.message("Tweak exceeds 512 MiB.") }
            let retained = FileManager.default.temporaryDirectory.appendingPathComponent("tweak-download-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: retained)
            received = retained
        } catch { downloadFailure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let callback = continuation
        continuation = nil
        if let failure = downloadFailure ?? error {
            if let received { try? FileManager.default.removeItem(at: received) }
            callback?.resume(throwing: failure)
        } else if let received { callback?.resume(returning: received) }
        else { callback?.resume(throwing: SideloadError.message("Tweak download returned no file.")) }
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
