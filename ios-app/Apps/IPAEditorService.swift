import Foundation
import UIKit
import AirliftFFI

@_silgen_name("al_ipa_editor_run")
private func al_ipa_editor_run(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

/// All Rust operations block. Call only from a detached task.
enum IPAEditorService {
    static let maximumFileSize: Int64 = 512 * 1024 * 1024

    static func run(_ operation: String, input: URL, output: URL? = nil,
                    executable: String? = nil, libraries: [URL] = []) throws {
        var request: [String: Any] = ["operation": operation, "input": input.path]
        if let output { request["output"] = output.path }
        if let executable { request["executable"] = executable }
        request["libraries"] = libraries.map(\.path)
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(data: data, encoding: .utf8),
              let response = text.withCString({ al_ipa_editor_run($0) }) else {
            throw SideloadError.message("IPA editor did not respond.")
        }
        defer { al_string_free(response) }
        let resultData = Data(String(cString: response).utf8)
        guard let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any],
              result["ok"] as? Bool == true else {
            let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
            throw SideloadError.message(result?["error"] as? String ?? "IPA editor failed.")
        }
    }

    static func validBundleID(_ value: String) -> Bool {
        value.count <= 255 &&
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#, options: .regularExpression) != nil
    }

    static func app(in extraction: URL) throws -> URL {
        let payload = extraction.appendingPathComponent("Payload", isDirectory: true)
        let apps = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard apps.count == 1 else { throw SideloadError.message("IPA must contain exactly one Payload app.") }
        return apps[0]
    }

    static func info(in app: URL) throws -> [String: Any] {
        let plistURL = app.appendingPathComponent("Info.plist")
        guard (try plistURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 4 * 1024 * 1024 else {
            throw SideloadError.message("App Info.plist exceeds 4 MiB.")
        }
        let data = try Data(contentsOf: plistURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String, validBundleID(id),
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), !executable.contains("\\"),
              executable != ".", executable != ".." else {
            throw SideloadError.message("Invalid app metadata, bundle identifier or executable path.")
        }
        return info
    }

    /// Copy the *unmodified extraction* every time. Reopening the editor never
    /// injects twice or accumulates stale names/icons from earlier previews.
    static func prepare(_ pending: PendingImport, options: IPAEditOptions, libraries: [URL]) throws -> IPAEditedResult {
        let fm = FileManager.default
        let sourceRoot = pending.workDir.appendingPathComponent("x", isDirectory: true)
        let stage = pending.workDir.appendingPathComponent("edit-\(UUID().uuidString)", isDirectory: true)
        let output = pending.workDir.appendingPathComponent("edited-\(UUID().uuidString).ipa")
        do {
            try fm.copyItem(at: sourceRoot, to: stage)
            let app = try self.app(in: stage)
            var info = try self.info(in: app)
            try run("validate", input: app.appendingPathComponent(info["CFBundleExecutable"] as! String))
            let originalID = info["CFBundleIdentifier"] as! String
            let displayName = options.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = options.version.trimmingCharacters(in: .whitespacesAndNewlines)
            let newID = options.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty, displayName.count <= 100, !version.isEmpty, version.count <= 64 else {
                throw SideloadError.message("Enter a display name and version.")
            }
            guard validBundleID(newID) else { throw SideloadError.message("Use a valid reverse-domain bundle ID, for example com.example.app.") }
            info["CFBundleDisplayName"] = displayName
            info["CFBundleName"] = displayName
            info["CFBundleShortVersionString"] = version
            // Bundle versions are deliberately separate from the public version.
            info["CFBundleIdentifier"] = newID
            if newID != originalID {
                try updateNestedBundleIDs(app: app, old: originalID, new: newID)
            }
            switch options.minimumOS {
            case .keep: break
            case .remove: info.removeValue(forKey: "MinimumOSVersion")
            case .lower:
                let requested = options.minimumVersion.trimmingCharacters(in: .whitespacesAndNewlines)
                guard requested.range(of: #"^[0-9]{1,2}(\.[0-9]{1,2}){0,2}$"#, options: .regularExpression) != nil else {
                    throw SideloadError.message("Use an iOS version such as 15.0.")
                }
                if let old = info["MinimumOSVersion"] as? String,
                   requested.compare(old, options: .numeric) == .orderedDescending {
                    throw SideloadError.message("This control only lowers MinimumOSVersion.")
                }
                info["MinimumOSVersion"] = requested
            }
            if let png = options.iconPNG {
                try installIcon(png: png, in: app, info: &info)
            }
            let plistURL = app.appendingPathComponent("Info.plist")
            try write(info, to: plistURL)
            // Localized CFBundleDisplayName overrides the root plist, including
            // on real installation. Remove only name overrides, not translations.
            for language in try fm.contentsOfDirectory(at: app, includingPropertiesForKeys: nil) where language.pathExtension == "lproj" {
                let strings = language.appendingPathComponent("InfoPlist.strings")
                guard let values = try? strings.resourceValues(forKeys: [.fileSizeKey]),
                      (values.fileSize ?? 0) <= 4 * 1024 * 1024,
                      let d = try? Data(contentsOf: strings),
                      var localized = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { continue }
                localized.removeValue(forKey: "CFBundleDisplayName")
                localized.removeValue(forKey: "CFBundleName")
                try write(localized, to: strings)
            }
            if !libraries.isEmpty {
                try run("inject", input: app, executable: info["CFBundleExecutable"] as? String, libraries: libraries)
            }
            // Repack *before* swapping PendingImport. Real installs, moves and
            // refreshes use this same edited originalIPA, not an old source.
            try run("pack", input: stage, output: output)
            let size = (try fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
            return IPAEditedResult(app: app, ipa: output, info: info, size: size, stage: stage)
        } catch {
            try? fm.removeItem(at: stage)
            try? fm.removeItem(at: output)
            throw error
        }
    }

    private static func write(_ info: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: url, options: .atomic)
    }

    private static func updateNestedBundleIDs(app: URL, old: String, new: String) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: app, includingPropertiesForKeys: nil) else { return }
        while let url = e.nextObject() as? URL {
            guard url.lastPathComponent == "Info.plist", url.deletingLastPathComponent() != app else { continue }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  (values.fileSize ?? 0) <= 4 * 1024 * 1024,
                  let data = try? Data(contentsOf: url),
                  var info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { continue }
            var changed = false
            if let id = info["CFBundleIdentifier"] as? String, id.hasPrefix(old + ".") {
                info["CFBundleIdentifier"] = new + String(id.dropFirst(old.count)); changed = true
            }
            if var attrs = info["NSExtension"] as? [String: Any],
               var nested = attrs["NSExtensionAttributes"] as? [String: Any],
               let containing = nested["WKAppBundleIdentifier"] as? String, containing == old || containing.hasPrefix(old + ".") {
                nested["WKAppBundleIdentifier"] = new + String(containing.dropFirst(old.count))
                attrs["NSExtensionAttributes"] = nested; info["NSExtension"] = attrs; changed = true
            }
            if let id = info["WKCompanionAppBundleIdentifier"] as? String, id == old || id.hasPrefix(old + ".") {
                info["WKCompanionAppBundleIdentifier"] = new + String(id.dropFirst(old.count)); changed = true
            }
            if changed { try write(info, to: url) }
        }
    }

    private static func installIcon(png: Data, in app: URL, info: inout [String: Any]) throws {
        guard png.count <= 16 * 1024 * 1024,
              let image = UIImage(data: png), image.size.width > 0, image.size.height > 0 else {
            throw SideloadError.message("Choose a valid PNG or JPEG icon.")
        }
        let sizes: [(CGFloat, Int)] = [(60, 2), (60, 3), (76, 1), (76, 2), (83.5, 2)]
        var files: [String] = []
        for (points, scale) in sizes {
            let format = UIGraphicsImageRendererFormat()
            format.scale = CGFloat(scale); format.opaque = true
            let name = "MirsaEditedIcon\(Int(points * 10))@\(scale)x"
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: points, height: points), format: format)
            let data = renderer.pngData { ctx in
                UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: points, height: points))
                image.draw(in: CGRect(x: 0, y: 0, width: points, height: points))
            }
            try data.write(to: app.appendingPathComponent(name + ".png"), options: .atomic)
            files.append(name)
        }
        let primary: [String: Any] = ["CFBundleIconFiles": files, "UIPrerenderedIcon": true]
        info["CFBundleIcons"] = ["CFBundlePrimaryIcon": primary]
        info["CFBundleIcons~ipad"] = ["CFBundlePrimaryIcon": primary]
        info.removeValue(forKey: "CFBundleIcons~iphone")
        info.removeValue(forKey: "CFBundleIconFiles~iphone")
        info.removeValue(forKey: "CFBundleIconFiles~ipad")
        info.removeValue(forKey: "CFBundleIconName~iphone")
        info.removeValue(forKey: "CFBundleIconName~ipad")
        info["CFBundleIconFiles"] = files
        info.removeValue(forKey: "CFBundleIconName")
        info.removeValue(forKey: "CFBundleIconFile")
    }
}

enum IPAMinimumOS: String, CaseIterable, Sendable { case keep, lower, remove }
struct IPAEditOptions: Sendable {
    var displayName: String
    var version: String
    var bundleID: String
    var minimumOS: IPAMinimumOS = .keep
    var minimumVersion: String = ""
    var iconPNG: Data?
    var tweakIDs: Set<UUID> = []
}
struct IPAEditedResult {
    let app: URL
    let ipa: URL
    let info: [String: Any]
    let size: Int64
    let stage: URL
}
