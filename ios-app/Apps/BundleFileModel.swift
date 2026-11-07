import Foundation

/// Staged, non-destructive project file operations. Nothing here touches the original
/// extracted bundle; everything is applied to the signing workspace copy by BundleStagingApplier.
enum BundleFileError: Error, Equatable {
    case invalidPath(String), outsideBundle(String), symlinkNotAllowed(String), protectedPath(String, String)
    case notFound(String), alreadyExists(String), tooLarge(Int), notText, invalidPlist(String)
    case typeMismatch(expected: String), importTooLarge(Int), conflict(String), applyFailed(String)
}

enum BundleFileKind: Equatable { case directory, plist, text, binary }

struct BundleEntry: Identifiable, Equatable {
    let path: String          // bundle-relative, "/"-separated, "" = root
    let name: String
    let kind: BundleFileKind
    let size: Int
    var id: String { path }
}

enum StagedBundleOp: Codable, Equatable {
    case rename(path: String, newName: String)
    case delete(path: String)
    case importFile(directory: String, name: String, blob: String) // blob = file name in staging dir
    case writeFile(path: String, blob: String)                      // edited text / plist bytes

    var summary: String {
        switch self {
        case let .rename(p, n): return "Rename \(p) -> \(n)"
        case let .delete(p): return "Delete \(p)"
        case let .importFile(d, n, _): return "Import \(d.isEmpty ? "" : d + "/")\(n)"
        case let .writeFile(p, _): return "Edit \(p)"
        }
    }
}

/// Persistable overlay for one project; blobs live in stagingDirectory.
struct BundleOverlay: Codable, Equatable {
    var ops: [StagedBundleOp] = []
    var isEmpty: Bool { ops.isEmpty }
}

enum BundleLimits {
    static let maxTextBytes = 512 * 1024
    static let maxPlistBytes = 4 * 1024 * 1024
    static let maxImportBytes = 64 * 1024 * 1024
    static let maxPlistDepth = 32
    static let maxEntriesPerDirectory = 5000
}
