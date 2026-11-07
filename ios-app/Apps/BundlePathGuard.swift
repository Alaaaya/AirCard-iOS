import Foundation

/// Strict bundle-relative path handling. Every component is checked with lstat semantics.
enum BundlePath {
    static func components(_ path: String) throws -> [String] {
        if path.isEmpty { return [] }
        guard !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { throw BundleFileError.invalidPath(path) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for p in parts where p.isEmpty || p == "." || p == ".." { throw BundleFileError.invalidPath(path) }
        return parts
    }
    static func validName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\0"), !name.contains("\\") else { throw BundleFileError.invalidPath(name) }
    }
    static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
    /// Resolve under root, rejecting symlinks in every existing component (and dangling ones).
    static func resolve(_ path: String, in root: URL, mustExist: Bool = true) throws -> URL {
        var url = root
        let fm = FileManager.default
        if isSymlink(root) { throw BundleFileError.symlinkNotAllowed("") }
        for c in try components(path) {
            url.appendPathComponent(c)
            if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { throw BundleFileError.symlinkNotAllowed(path) }
        }
        if mustExist && (try? fm.attributesOfItem(atPath: url.path)) == nil { throw BundleFileError.notFound(path) }
        let rootPath = root.standardizedFileURL.path
        guard url.standardizedFileURL.path == rootPath || url.standardizedFileURL.path.hasPrefix(rootPath + "/") else {
            throw BundleFileError.outsideBundle(path)
        }
        return url
    }
    static func join(_ dir: String, _ name: String) -> String { dir.isEmpty ? name : dir + "/" + name }
    static func parent(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "" }
        return String(path[..<i])
    }
    static func lastComponent(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? "" }
}

/// Guardrails: anything that would silently invalidate the app is refused with an explanation.
struct BundleGuard {
    let root: URL
    let executableName: String?
    init(root: URL) {
        self.root = root
        let info = root.appendingPathComponent("Info.plist")
        if let d = try? Data(contentsOf: info),
           let o = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any] {
            executableName = o["CFBundleExecutable"] as? String
        } else { executableName = nil }
    }
    /// nil = allowed, otherwise the reason.
    func protectedReason(_ path: String) -> String? {
        let comps = (try? BundlePath.components(path)) ?? []
        guard let first = comps.first else { return "The bundle root cannot be changed." }
        if path == "Info.plist" { return "Info.plist is required; edit it instead of renaming or deleting." }
        if first == "_CodeSignature" { return "Signature data is regenerated at signing; do not touch it." }
        if path == "embedded.mobileprovision" { return "The provisioning profile is replaced at signing." }
        if let e = executableName, path == e { return "This is the main executable; the app would not launch." }
        if path == "PkgInfo" { return "PkgInfo is required metadata." }
        if comps.count >= 2, ["Frameworks", "PlugIns", "Extensions", "AppClips", "Watch"].contains(first) {
            if comps.count == 2 { return "Removing or renaming embedded code breaks the app and its signature." }
            let leaf = comps[1]
            if leaf.hasSuffix(".framework") || leaf.hasSuffix(".appex") || leaf.hasSuffix(".app") {
                if comps.count == 3, comps[2] == "Info.plist" { return "Embedded bundle Info.plist is required." }
                if comps.count == 3, comps[2] == leaf.split(separator: ".").dropLast().joined(separator: ".") {
                    return "This is an embedded executable."
                }
            }
        }
        if comps.last?.hasSuffix(".dylib") == true, first == "Frameworks" { return "Embedded libraries are linked by the executable." }
        return nil
    }

    /// Case-insensitive + ancestor-aware check for DESTINATIONS (rename target, import, edited names).
    func destinationReason(_ path: String) -> String? {
        let comps = (try? BundlePath.components(path)) ?? []
        guard !comps.isEmpty else { return "The bundle root cannot be changed." }
        for i in 1...comps.count {
            let prefix = comps[0..<i].joined(separator: "/")
            if let r = protectedReason(prefix) { return i == comps.count ? r : "Inside protected item \(prefix): \(r)" }
        }
        let lower = comps.map { $0.lowercased() }
        let flat = lower.joined(separator: "/")
        if flat == "info.plist" || flat == "pkginfo" || flat == "embedded.mobileprovision" || lower[0] == "_codesignature" {
            return "This name is reserved (case-insensitive): \(path)"
        }
        if let e = executableName?.lowercased(), flat == e { return "This name is the main executable (case-insensitive)." }
        let canon = ["frameworks": "Frameworks", "plugins": "PlugIns", "extensions": "Extensions", "appclips": "AppClips", "watch": "Watch"]
        if let c = canon[lower[0]], c != comps[0] {
            var alias = comps; alias[0] = c
            if let r = protectedReason(alias.joined(separator: "/")) { return "Case alias of a protected item: \(r)" }
        }
        return nil
    }
}
