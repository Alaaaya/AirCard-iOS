import Foundation
import Darwin
import SwiftUI

/// A separate identity prevents the form's keystrokes from rebuilding the
/// background. Keep exactly the same glass/colors; pause only during interaction.
struct PersonalProjectBackdrop: View, Equatable {
    let paused: Bool
    var body: some View { AuroraBackground(paused: paused) }
}

/// Coalesces draft persistence, not UI bindings or signing validation.
/// Flush synchronously at navigation/sign boundaries so the latest edit survives.
@MainActor
final class PersonalProjectDraftWriter: ObservableObject {
    private var pending: (PersonalProjectDraft, URL)?
    private var task: Task<Void, Never>?
    private let delay: UInt64
    private let write: (Data, URL) throws -> Void
    init(delay: UInt64 = 350_000_000, write: @escaping (Data, URL) throws -> Void = {
        try $0.write(to: $1, options: [.atomic, .completeFileProtection])
    }) { self.delay = delay; self.write = write }
    func schedule(_ draft: PersonalProjectDraft, to url: URL) {
        pending = (draft, url)
        task?.cancel()
        task = Task { [weak self, delay] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            self?.flush()
        }
    }
    func flush() {
        task?.cancel(); task = nil
        guard let (draft, url) = pending else { return }
        pending = nil
        if let data = try? JSONEncoder().encode(draft) { try? write(data, url) }
    }
}

/// UI metadata only. Never caches authorization, profiles, keys or signing
/// validation. Size/date/file identity invalidate replacement or changed inputs.
actor PersonalProjectInspection {
    struct Key: Hashable {
        let path: String
        let size: Int64
        let device: Int64
        let inode: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        init(_ url: URL) throws {
            // URL.resourceValues caches metadata on the URL instance. Always
            // query the filesystem, preserving nanoseconds and change time.
            var metadata = stat()
            guard url.withUnsafeFileSystemRepresentation({ path in
                guard let path else { return false }
                return lstat(path, &metadata) == 0
            }), (metadata.st_mode & S_IFMT) == S_IFREG else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.path = url.standardizedFileURL.path
            size = Int64(metadata.st_size)
            device = Int64(metadata.st_dev)
            inode = UInt64(metadata.st_ino)
            modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
            changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
        }
    }

    struct Result { let extensions: Int; let dependencies: [String] }
    static let shared = PersonalProjectInspection()
    private var cache: [Key: Result] = [:]
    private var pending: [Key: Task<Result?, Never>] = [:]

    func inspect(_ url: URL) async -> Result? {
        guard let key = try? Key(url) else { return nil }
        if let result = cache[key] { return result }
        if let task = pending[key] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> Result? in
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("inspect-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: dir) }
            do {
                try IPAEditorService.run("extract", input: url, output: dir)
                let app = try IPAEditorService.app(in: dir)
                let info = try IPAEditorService.info(in: app)
                guard let executable = info["CFBundleExecutable"] as? String else { return nil }
                let extensions = (try? fm.contentsOfDirectory(atPath: app.appendingPathComponent("PlugIns").path))?
                    .filter { $0.hasSuffix(".appex") }.count ?? 0
                let dependencies = try IPAEditorService.dependencies(of: app.appendingPathComponent(executable))
                return Result(extensions: extensions, dependencies: dependencies)
            } catch { return nil }
        }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        // Do not retain stale results if the source changed during extraction.
        guard (try? Key(url)) == key else { return nil }
        if let result {
            cache = cache.filter { $0.key.path != key.path }
            if cache.count >= 12 { cache.removeAll() }
            cache[key] = result
        }
        return result
    }
}
