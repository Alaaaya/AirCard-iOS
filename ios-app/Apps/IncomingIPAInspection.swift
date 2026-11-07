import Foundation
import UIKit
import ImageIO

struct IncomingEntitlement: Decodable, Identifiable {
    let key: String
    let value: String
    var id: String { key }
}
struct IncomingProfile: Decodable {
    let name: String
    let shortID: String
    let certificateNames: [String]
    let entitlements: [IncomingEntitlement]
}
struct IncomingSignature: Decodable {
    let signaturePresent: Bool?
    let entitlements: [IncomingEntitlement]
    let entitlementsUnavailable: Bool?
    let embeddedProfile: IncomingProfile?
    let profileUnavailable: Bool?
}
struct IncomingIPAPreview {
    let name: String
    let bundleID: String
    let version: String
    let size: Int64
    let icon: UIImage?
    let signature: IncomingSignature
}
enum IncomingIPAInspection {
    /// Read-only. Reuses the hardened archive extractor. No library mutation,
    /// pending import, signer, installation, URL opening or network operations.
    static func load(_ url: URL) throws -> IncomingIPAPreview {
        let fm = FileManager.default
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, Int64(size) <= IPAEditorService.maximumFileSize else {
            throw SideloadError.message("IPA exceeds preview limits.")
        }
        let root = fm.temporaryDirectory.appendingPathComponent("incoming-preview-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        // Rust extraction requires a nonexistent destination.
        try IPAEditorService.run("extract", input: url, output: root)
        let app = try IPAEditorService.app(in: root)
        let out = root.appendingPathComponent("incoming-preview.json")
        try IPAEditorService.run("incoming_preview", input: app, output: out)
        let signature = try decode(IncomingSignature.self, at: out)
        let info = try IPAEditorService.info(in: app)
        let id = info["CFBundleIdentifier"] as! String
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String
        return IncomingIPAPreview(
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? id,
            bundleID: id, version: version + (build.map { " (\($0))" } ?? ""),
            size: Int64(size), icon: thumbnail(in: app, info: info), signature: signature)
    }
    private static func thumbnail(in app: URL, info: [String: Any]) -> UIImage? {
        var names = info["CFBundleIconFiles"] as? [String] ?? []
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
            names += primary["CFBundleIconFiles"] as? [String] ?? []
            if let name = primary["CFBundleIconName"] as? String { names.append(name) }
        }
        if let name = info["CFBundleIconFile"] as? String { names.append(name) }
        names.append("AppIcon")
        let files = (try? FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])) ?? []
        for file in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
        where file.pathExtension.lowercased() == "png" && names.contains(where: { file.lastPathComponent.hasPrefix($0) }) {
            guard let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize, size <= 16*1024*1024,
                  let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= 8192, h <= 8192,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 180,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: false
                  ] as CFDictionary) else { continue }
            return UIImage(cgImage: image)
        }
        return nil
    }
    static func savedProfile(_ bytes: Data) throws -> IncomingProfile {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("incoming-profile-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.complete])
        defer { try? fm.removeItem(at: root) }
        let input = root.appendingPathComponent("profile.mobileprovision")
        try bytes.write(to: input, options: [.atomic, .completeFileProtection])
        let output = root.appendingPathComponent("profile.json")
        try IPAEditorService.run("incoming_profile", input: input, output: output)
        return try decode(IncomingProfile.self, at: output)
    }
    private static func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2*1024*1024 else {
            throw SideloadError.message("Preview metadata exceeds limits.")
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}


// UI metadata cache only; never retains selected identities, secrets or trust.
// Bounded per-process lifetime and file identity invalidation prevent stale previews.
actor IncomingIPAPreviewCache {
    static let shared = IncomingIPAPreviewCache()
    private var cache: [PersonalProjectInspection.Key: IncomingIPAPreview] = [:]
    func preview(_ url: URL) async throws -> IncomingIPAPreview {
        let key = try PersonalProjectInspection.Key(url)
        if let value = cache[key] { return value }
        let value = try await Task.detached(priority: .userInitiated) { try IncomingIPAInspection.load(url) }.value
        guard try PersonalProjectInspection.Key(url) == key else { throw CocoaError(.fileReadCorruptFile) }
        cache = cache.filter { $0.key.path != key.path }
        if cache.count >= 3 { cache.removeAll() }
        cache[key] = value
        return value
    }
}
