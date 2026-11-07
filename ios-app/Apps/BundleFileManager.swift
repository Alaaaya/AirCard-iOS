import Foundation

enum BundleFileContent {
    case plist(PlistDocument), text(String), binary(size: Int), directory
}

/// Browses an EXTRACTED .app bundle (never mutated) and stages edits in an overlay.
/// Integration contract: create one per project, persist `overlay` (Codable) next to the project,
/// then call `apply(to:)` with the signing WORKSPACE copy BEFORE nested codesigning/prepare.
final class BundleFileManager {
    let root: URL
    let stagingDirectory: URL
    private(set) var overlay: BundleOverlay
    private let guardrails: BundleGuard

    init(root: URL, stagingDirectory: URL, overlay: BundleOverlay = BundleOverlay()) throws {
        guard !BundlePath.isSymlink(root) else { throw BundleFileError.symlinkNotAllowed("") }
        self.root = root; self.stagingDirectory = stagingDirectory; self.overlay = overlay
        self.guardrails = BundleGuard(root: root)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    }

    // MARK: browsing (original bundle + virtual overlay)
    enum Source: Equatable { case original(String), added(String), none }

    /// Maps an effective (post-overlay) path back to the original bundle or a staged blob.
    func source(of path: String) -> Source {
        var p = path
        for op in overlay.ops.reversed() {
            switch op {
            case let .rename(old, newName):
                let newPath = BundlePath.join(BundlePath.parent(old), newName)
                if p == newPath || p.hasPrefix(newPath + "/") { p = old + p.dropFirst(newPath.count) }
                else if p == old || p.hasPrefix(old + "/") { return .none }
            case let .delete(d): if p == d || p.hasPrefix(d + "/") { return .none }
            case let .importFile(dir, name, blob): if p == BundlePath.join(dir, name) { return .added(blob) }
            case let .writeFile(w, blob): if p == w { return .added(blob) }
            }
        }
        return .original(p)
    }
    func exists(_ path: String) -> Bool {
        if path.isEmpty { return true }
        switch source(of: path) {
        case .none: return false
        case .added: return true
        case let .original(o): return (try? BundlePath.resolve(o, in: root)) != nil
        }
    }

    func list(_ directory: String) throws -> [BundleEntry] {
        var names = Set<String>()
        if case let .original(o) = source(of: directory), let url = try? BundlePath.resolve(o, in: root) {
            let kids = try FileManager.default.contentsOfDirectory(atPath: url.path)
            guard kids.count <= BundleLimits.maxEntriesPerDirectory else { throw BundleFileError.tooLarge(kids.count) }
            names.formUnion(kids)
            // renamed-away originals are filtered by exists(); renamed-in names added below
        }
        for op in overlay.ops {
            switch op {
            case let .rename(old, n) where BundlePath.parent(old) == directory: names.insert(n)
            case let .importFile(d, n, _) where d == directory: names.insert(n)
            default: break
            }
        }
        var out: [BundleEntry] = []
        for n in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let p = BundlePath.join(directory, n)
            guard exists(p) else { continue }
            out.append(try entry(p))
        }
        return out
    }

    private func fileURL(of path: String) throws -> URL {
        switch source(of: path) {
        case .none: throw BundleFileError.notFound(path)
        case let .added(b): return try BundlePath.resolve(b, in: stagingDirectory)
        case let .original(o): return try BundlePath.resolve(o, in: root)
        }
    }
    func entry(_ path: String) throws -> BundleEntry {
        let url = try fileURL(of: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let isDir = attrs[.type] as? FileAttributeType == .typeDirectory
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let name = BundlePath.lastComponent(path)
        if isDir { return BundleEntry(path: path, name: name, kind: .directory, size: 0) }
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw BundleFileError.symlinkNotAllowed(path) }
        let head = try Self.head(url, 16)
        let kind: BundleFileKind
        if head.starts(with: Data("bplist00".utf8)) { kind = .plist }
        else if Self.isText(try Self.head(url, 4096)) {
            kind = (name.hasSuffix(".plist") || Self.looksXMLPlist(head)) ? .plist : .text
        } else { kind = .binary }
        return BundleEntry(path: path, name: name, kind: kind, size: size)
    }
    static func head(_ url: URL, _ n: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        return try h.read(upToCount: n) ?? Data()
    }
    static func looksXMLPlist(_ d: Data) -> Bool { String(decoding: d, as: UTF8.self).contains("<?xml") }
    /// Text = valid UTF-8 (prefix may cut a scalar), no NUL, few control bytes.
    static func isText(_ d: Data) -> Bool {
        if d.isEmpty { return true }
        if d.contains(0) { return false }
        let ctrl = d.filter { $0 < 9 || ($0 > 13 && $0 < 32) }.count
        if ctrl * 100 > d.count { return false }
        var s = d
        for _ in 0..<4 { if String(data: s, encoding: .utf8) != nil { return true }; if s.isEmpty { break }; s.removeLast() }
        return false
    }

    func read(_ path: String) throws -> BundleFileContent {
        let e = try entry(path)
        let url = try fileURL(of: path)
        switch e.kind {
        case .directory: return .directory
        case .binary: return .binary(size: e.size)
        case .plist: return .plist(try PlistDocument(data: try Self.readLimited(url, BundleLimits.maxPlistBytes)))
        case .text: return .text(String(decoding: try Self.readLimited(url, BundleLimits.maxTextBytes), as: UTF8.self))
        }
    }
    static func readLimited(_ url: URL, _ limit: Int) throws -> Data {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= limit else { throw BundleFileError.tooLarge(size) }
        return try Data(contentsOf: url)
    }

    // MARK: staging
    /// nil = allowed. Also use this to render warnings before the user confirms.
    func protectedReason(_ path: String) -> String? {
        switch source(of: path) {
        case let .original(o): return guardrails.protectedReason(o) ?? (o != path ? guardrails.protectedReason(path) : nil)
        default: return nil
        }
    }
    func stageRename(_ path: String, to newName: String) throws {
        try BundlePath.validName(newName)
        _ = try BundlePath.components(path)
        guard exists(path) else { throw BundleFileError.notFound(path) }
        if let r = protectedReason(path) { throw BundleFileError.protectedPath(path, r) }
        let target = BundlePath.join(BundlePath.parent(path), newName)
        if target == path { return }
        guard !exists(target) else { throw BundleFileError.alreadyExists(target) }
        if let r = guardrails.protectedReason(target), case .original = source(of: path) { _ = r } // names are re-checked at apply
        overlay.ops.append(.rename(path: path, newName: newName))
    }
    func stageDelete(_ path: String) throws {
        _ = try BundlePath.components(path)
        guard exists(path) else { throw BundleFileError.notFound(path) }
        if let r = protectedReason(path) { throw BundleFileError.protectedPath(path, r) }
        // refuse deleting a directory that contains protected items
        if let e = try? entry(path), e.kind == .directory, let r = try protectedDescendant(path) {
            throw BundleFileError.protectedPath(path, r)
        }
        overlay.ops.append(.delete(path: path))
    }
    private func protectedDescendant(_ dir: String) throws -> String? {
        for c in try list(dir) {
            if let r = protectedReason(c.path) { return "Contains \(c.name): \(r)" }
            if c.kind == .directory, let r = try protectedDescendant(c.path) { return r }
        }
        return nil
    }
    func stageImport(from source: URL, intoDirectory dir: String, name: String? = nil) throws {
        let n = name ?? source.lastPathComponent
        try BundlePath.validName(n)
        guard exists(dir), try entry(dir).kind == .directory || dir.isEmpty else { throw BundleFileError.notFound(dir) }
        let dest = BundlePath.join(dir, n)
        guard !exists(dest) else { throw BundleFileError.alreadyExists(dest) }
        if let r = guardrails.protectedReason(dest) { throw BundleFileError.protectedPath(dest, r) }
        let blob = try copyBlob(from: source)
        overlay.ops.append(.importFile(directory: dir, name: n, blob: blob))
    }
    func stageWrite(_ path: String, data: Data) throws {
        guard exists(path) else { throw BundleFileError.notFound(path) }
        let e = try entry(path)
        guard e.kind == .plist || e.kind == .text else { throw BundleFileError.notText }
        guard data.count <= (e.kind == .plist ? BundleLimits.maxPlistBytes : BundleLimits.maxTextBytes) else { throw BundleFileError.tooLarge(data.count) }
        if e.kind == .plist {
            let doc = try PlistDocument(data: data)
            if case .original(let o) = source(of: path), o == "Info.plist" || path == "Info.plist" {
                let r = InfoPlistGuard.check(doc, originalExecutable: guardrails.executableName)
                if let first = r.errors.first { throw BundleFileError.protectedPath(path, first) }
            }
        } else { guard String(data: data, encoding: .utf8) != nil else { throw BundleFileError.notText } }
        let blob = "blob-\(UUID().uuidString)"
        try data.write(to: stagingDirectory.appendingPathComponent(blob), options: .atomic)
        overlay.ops.append(.writeFile(path: path, blob: blob))
    }
    /// Convenience: stage an edited plist document in its original format.
    func stageWrite(_ path: String, plist: PlistDocument) throws { try stageWrite(path, data: try plist.serialized()) }
    func stageWrite(_ path: String, text: String) throws { try stageWrite(path, data: Data(text.utf8)) }

    func unstage(at index: Int) {
        guard overlay.ops.indices.contains(index) else { return }
        overlay.ops.remove(at: index)
        // later ops may depend on this one; drop any that no longer validate
        var kept: [StagedBundleOp] = []
        let all = overlay.ops; overlay.ops = []
        for op in all { overlay.ops = kept; if (try? validate(op)) != nil { kept.append(op) } }
        overlay.ops = kept
    }
    func discardAll() { overlay = BundleOverlay(); try? clearBlobs(keeping: []) }
    private func validate(_ op: StagedBundleOp) throws {
        switch op {
        case let .rename(p, n): guard exists(p) else { throw BundleFileError.notFound(p) }; try BundlePath.validName(n)
        case let .delete(p): guard exists(p) else { throw BundleFileError.notFound(p) }
        case let .importFile(d, n, _): guard exists(d), !exists(BundlePath.join(d, n)) else { throw BundleFileError.conflict(n) }
        case let .writeFile(p, _): guard exists(p) else { throw BundleFileError.notFound(p) }
        }
    }
    private func clearBlobs(keeping: Set<String>) throws {
        for f in try FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path) where !keeping.contains(f) {
            try? FileManager.default.removeItem(at: stagingDirectory.appendingPathComponent(f))
        }
    }
    private func copyBlob(from source: URL) throws -> String {
        let fm = FileManager.default
        if BundlePath.isSymlink(source) { throw BundleFileError.symlinkNotAllowed(source.lastPathComponent) }
        let a = try fm.attributesOfItem(atPath: source.path)
        guard a[.type] as? FileAttributeType == .typeRegular else { throw BundleFileError.invalidPath(source.lastPathComponent) }
        let size = (a[.size] as? NSNumber)?.intValue ?? 0
        guard size <= BundleLimits.maxImportBytes else { throw BundleFileError.importTooLarge(size) }
        let blob = "blob-\(UUID().uuidString)"
        let tmp = stagingDirectory.appendingPathComponent(blob + ".part")
        try fm.copyItem(at: source, to: tmp)
        // revalidate after copy (race): still regular and same size
        let b = try fm.attributesOfItem(atPath: tmp.path)
        guard b[.type] as? FileAttributeType == .typeRegular, (b[.size] as? NSNumber)?.intValue == size || size == 0 else {
            try? fm.removeItem(at: tmp); throw BundleFileError.conflict("source changed during import")
        }
        try fm.moveItem(at: tmp, to: stagingDirectory.appendingPathComponent(blob))
        return blob
    }

    // MARK: apply
    /// Applies the overlay to the signing workspace copy (NEVER the original). All-or-nothing:
    /// replaced/removed items are moved to a backup directory first and restored on any failure.
    func apply(to workspace: URL) throws {
        try BundleStagingApplier.apply(overlay, blobs: stagingDirectory, original: root, to: workspace)
    }
}

enum BundleStagingApplier {
    static func apply(_ overlay: BundleOverlay, blobs: URL, original: URL, to workspace: URL) throws {
        guard !overlay.isEmpty else { return }
        let fm = FileManager.default
        guard workspace.standardizedFileURL.path != original.standardizedFileURL.path,
              !workspace.standardizedFileURL.path.hasPrefix(original.standardizedFileURL.path + "/"),
              !original.standardizedFileURL.path.hasPrefix(workspace.standardizedFileURL.path + "/") else {
            throw BundleFileError.applyFailed("workspace must be a separate copy of the bundle")
        }
        let guardrails = BundleGuard(root: workspace)
        let backup = workspace.deletingLastPathComponent().appendingPathComponent(".mirsa-stage-\(UUID().uuidString)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: backup) }
        var undo: [() -> Void] = []
        var n = 0
        func stash(_ url: URL) throws {
            n += 1
            let b = backup.appendingPathComponent("\(n)")
            try fm.moveItem(at: url, to: b)
            undo.append { try? fm.removeItem(at: url); try? fm.moveItem(at: b, to: url) }
        }
        do {
            for op in overlay.ops {
                switch op {
                case let .rename(path, newName):
                    if let r = guardrails.protectedReason(path) { throw BundleFileError.protectedPath(path, r) }
                    try BundlePath.validName(newName)
                    let src = try BundlePath.resolve(path, in: workspace)
                    let dst = try BundlePath.resolve(BundlePath.join(BundlePath.parent(path), newName), in: workspace, mustExist: false)
                    guard (try? fm.attributesOfItem(atPath: dst.path)) == nil else { throw BundleFileError.alreadyExists(newName) }
                    try fm.moveItem(at: src, to: dst)
                    undo.append { try? fm.moveItem(at: dst, to: src) }
                case let .delete(path):
                    if let r = guardrails.protectedReason(path) { throw BundleFileError.protectedPath(path, r) }
                    try stash(try BundlePath.resolve(path, in: workspace))
                case let .importFile(dir, name, blob):
                    try BundlePath.validName(name)
                    let parent = try BundlePath.resolve(dir, in: workspace)
                    let dst = try BundlePath.resolve(BundlePath.join(dir, name), in: workspace, mustExist: false)
                    guard parent.path.count > 0, (try? fm.attributesOfItem(atPath: dst.path)) == nil else { throw BundleFileError.alreadyExists(name) }
                    try copyFile(try BundlePath.resolve(blob, in: blobs), to: dst, fm: fm)
                    undo.append { try? fm.removeItem(at: dst) }
                case let .writeFile(path, blob):
                    let dst = try BundlePath.resolve(path, in: workspace)
                    try stash(dst)
                    try copyFile(try BundlePath.resolve(blob, in: blobs), to: dst, fm: fm)
                }
            }
        } catch {
            for u in undo.reversed() { u() }
            if let e = error as? BundleFileError { throw e }
            throw BundleFileError.applyFailed(error.localizedDescription)
        }
    }
    private static func copyFile(_ src: URL, to dst: URL, fm: FileManager) throws {
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".mirsa-\(UUID().uuidString).part")
        try fm.copyItem(at: src, to: tmp)
        do { try fm.moveItem(at: tmp, to: dst) } catch { try? fm.removeItem(at: tmp); throw error }
    }
}
