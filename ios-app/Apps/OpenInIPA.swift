import Foundation

/// File-provider handoff only. Never reads a remote URL or modifies the original.
/// UUID-owned directories avoid filename traversal and isolate cleanup.
enum OpenInIPA {
    static let maximumBytes = 512 * 1024 * 1024

    static func snapshot(_ source: URL) throws -> URL {
        guard source.isFileURL, source.pathExtension.lowercased() == "ipa" else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileReadNoPermission)
        }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("mirsa-open-in-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.protectionKey: FileProtectionType.complete])
        let target = directory.appendingPathComponent("Import.ipa")
        do {
            var coordinationError: NSError?
            var readError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                do {
                    let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          let size = values.fileSize, size > 0, size <= maximumBytes else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                    try fm.copyItem(at: readable, to: target)
                    let copy = try target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard copy.isRegularFile == true, copy.isSymbolicLink != true,
                          let size = copy.fileSize, size > 0, size <= maximumBytes else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                    try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
                } catch { readError = error }
            }
            if let error = coordinationError { throw error }
            if let error = readError { throw error }
            return target
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    static func remove(_ snapshot: URL) {
        let parent = snapshot.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
              parent.lastPathComponent.hasPrefix("mirsa-open-in-") else { return }
        try? FileManager.default.removeItem(at: parent)
    }
}
