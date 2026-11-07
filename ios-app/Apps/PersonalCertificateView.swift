import SwiftUI
import UniformTypeIdentifiers
import Security
import AirliftFFI

@_silgen_name("al_ipa_editor_run")
private func personalEditorRun(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("al_ipa_editor_run_progress")
private func personalEditorRunProgress(_ request: UnsafePointer<CChar>,
    _ callback: @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64) -> Int32,
    _ context: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

private final class PersonalSigningCallback {
    let control: PersonalSigningControl
    let report: (PersonalSigningEvent) -> Void
    init(control: PersonalSigningControl, report: @escaping (PersonalSigningEvent) -> Void) {
        self.control = control; self.report = report
    }
}


@_silgen_name("al_personal_p12_import")
private func personalP12Import(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

struct PersonalProfileVerification: Codable, Equatable {
    struct Warning: Codable, Equatable {
        let code: String
        let message: String
        let profile_index: Int?
    }
    let profile_verification: String
    let warnings: [Warning]
    var isVerified: Bool { profile_verification == "verified" && warnings.isEmpty }
    static let unknown = PersonalProfileVerification(profile_verification: "unverified", warnings: [
        Warning(code: "profile_cms_unverified", message: "ما قدرنا نتحقق من توقيع Apple على البروفايل. فيك تكمّل، بس هاد مو تأكيد لصلاحيته. iOS بيفحصه كمان وقت التثبيت.", profile_index: nil)
    ])
    static func parse(_ result: [String: Any]) -> Self {
        guard let status = result["profile_verification"] as? String,
              ["verified", "unverified"].contains(status),
              let values = result["warnings"] as? [[String: Any]] else { return .unknown }
        let warnings = values.compactMap { value -> Warning? in
            guard let code = value["code"] as? String, let message = value["message"] as? String, !message.isEmpty else { return nil }
            return Warning(code: code, message: message, profile_index: value["profile_index"] as? Int)
        }
        guard warnings.count == values.count else { return .unknown }
        if status != "verified" && warnings.isEmpty { return .unknown }
        return Self(profile_verification: status, warnings: warnings)
    }
    var warningText: String { warnings.map(\.message).joined(separator: "\n") }
}

// Separate from Apple ID storage and its handover/export/wipe operations.
enum PersonalIdentityVault {
    private static let service = "com.alaa.mirsa.personal-signing"
    struct Material: Codable { let p12: Data; let password: String; let profile: Data; var verification: PersonalProfileVerification? = nil }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "identity"]
    }
    struct SavedIdentity: Identifiable {
        let id: String
        let material: Material
        let name: String
        let teamID: String
        let bundleID: String
        let expiry: Date?
        let profileType: String
        let verification: PersonalProfileVerification
        let entitlements: [String: Any]
        let devices: [String]
    }
    private struct Entry: Codable { let id: String; let material: Material }
    private struct Collection: Codable { var entries: [Entry]; var selected: String? }
    private static func collection() throws -> Collection {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return Collection(entries: [], selected: nil) }
        guard status == errSecSuccess, let data = value as? Data else {
            throw SideloadError.message("افتح قفل الآيفون لتقدر تستخدم شهاداتك.")
        }
        if let list = try? JSONDecoder().decode(Collection.self, from: data) { return list }
        let legacy = try JSONDecoder().decode(Material.self, from: data)
        return Collection(entries: [Entry(id: "legacy", material: legacy)], selected: "legacy")
    }
    private static func store(_ list: Collection) throws {
        let data = try JSONEncoder().encode(list)
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            changes.forEach { q[$0.key] = $0.value }
            q[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SideloadError.message("ما قدرت احفظ الشهادة بأمان.") }
    }
    static func load() throws -> Material? {
        let list = try collection()
        return list.entries.first(where: { $0.id == list.selected })?.material ?? list.entries.first?.material
    }
    static func selectedID() throws -> String? {
        let list = try collection()
        return list.selected ?? list.entries.first?.id
    }
    static func select(_ id: String) throws {
        var list = try collection()
        guard list.entries.contains(where: { $0.id == id }) else { throw SideloadError.message("الشهادة مو موجودة.") }
        list.selected = id
        try store(list)
    }
    static func save(_ material: Material) throws {
        var material = material
        material.verification = PersonalProfileVerification.parse(try importResult(material))
        var list = try collection()
        if let existing = list.entries.first(where: { $0.material.p12 == material.p12 && $0.material.profile == material.profile }) {
            list.entries.removeAll { $0.id == existing.id }
            list.entries.append(Entry(id: existing.id, material: material))
            list.selected = existing.id
        } else {
            guard list.entries.count < 30 else { throw SideloadError.message("احذف شهادة قديمة قبل إضافة شهادة جديدة.") }
            let entry = Entry(id: UUID().uuidString, material: material)
            list.entries.append(entry); list.selected = entry.id
        }
        try store(list)
    }
    static func remove(_ id: String) throws {
        var list = try collection()
        list.entries.removeAll { $0.id == id }
        if list.selected == id { list.selected = list.entries.first?.id }
        try store(list)
    }
    static func remove() throws {
        if let id = try selectedID() { try remove(id) }
    }
    static func savedIdentities() throws -> [SavedIdentity] {
        try collection().entries.map { entry in
            let details = try importResult(entry.material)
            return SavedIdentity(id: entry.id, material: entry.material,
                name: PersonalCertificateLabel.name(importDetails: details),
                teamID: details["teamID"] as? String ?? "",
                bundleID: details["bundleID"] as? String ?? "",
                expiry: (details["expiry"] as? Double).map { Date(timeIntervalSince1970: $0) },
                profileType: details["profileType"] as? String ?? "",
                verification: PersonalProfileVerification.parse(details),
                entitlements: details["profileEntitlements"] as? [String: Any] ?? [:],
                devices: details["provisionedDevices"] as? [String] ?? [])
        }
    }
    private static func importResult(_ material: Material) throws -> [String: Any] {
        let request: [String: Any] = [
            "p12": material.p12.base64EncodedString(),
            "password": material.password,
            "profile": material.profile.base64EncodedString()
        ]
        let bytes = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(data: bytes, encoding: .utf8),
              let response = text.withCString({ personalP12Import($0) }) else {
            throw SideloadError.message("P12 importer did not respond.")
        }
        defer { al_string_free(response) }
        let result = try JSONSerialization.jsonObject(with: Data(String(cString: response).utf8)) as? [String: Any]
        guard result?["ok"] as? Bool == true,
              let keyText = result?["key"] as? String, let key = Data(base64Encoded: keyText),
              let certText = result?["certificate"] as? String, let cert = Data(base64Encoded: certText) else {
            let messages: [String: (String, String)] = [
                "password": ("P12 password is incorrect, or the file integrity check failed.", "كلمة سر P12 غلط، أو الملف تالف."),
                "no_identity": ("P12 contains no certificate with its matching private key.", "ملف P12 ما فيه شهادة مع مفتاحها الخاص."),
                "multiple_identities": ("Several signing identities match this profile. Export a P12 with only the identity you want.", "في أكتر من شهادة بتطابق هالملف. صدّر P12 فيه الشهادة المطلوبة بس."),
                "encryption": ("This P12 encryption is unsupported. Re-export with AES-256 or legacy 3DES/RC2.", "تشفير ملف P12 مو مدعوم. صدّره من جديد بتشفير AES-256 أو 3DES/RC2."),
                "profile_mismatch": ("No P12 signing identity matches the provisioning profile.", "ولا شهادة بملف P12 بتطابق ملف mobileprovision."),
                "profile": ("Cannot read the provisioning profile or its developer certificates.", "ما قدرت اقرأ ملف mobileprovision أو الشهادات اللي فيه."),
                "key_type": ("Use an RSA signing certificate and its private key.", "استخدم شهادة توقيع RSA مع مفتاحها الخاص."),
                "invalid": ("P12 is damaged or has an unsupported structure.", "ملف P12 تالف أو تركيبته مو مدعومة.")
            ]
            let message = messages[result?["code"] as? String ?? "invalid"] ?? messages["invalid"]!
            throw SideloadError.message(MirsaTr.pick(message.0, message.1))
        }
        _ = key; _ = cert
        return result!
    }
    static func identity(_ material: Material) throws -> (Data, Data) {
        let result = try importResult(material)
        guard let keyText = result["key"] as? String, let key = Data(base64Encoded: keyText),
              let certText = result["certificate"] as? String, let cert = Data(base64Encoded: certText) else {
            throw SideloadError.message("الشهادة غير صالحة.")
        }
        return (key, cert)
    }
}

enum PersonalIconFixer {
    /// Opaque (alpha-free) copies of the app icon PNGs; iOS shows transparent icons on a white/blank tile.
    static func flattenAlpha(app: URL, info: [String: Any]) throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: app, includingPropertiesForKeys: [.fileSizeKey])
        for url in files where url.pathExtension.lowercased() == "png" && url.lastPathComponent.hasPrefix("AppIcon") {
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 <= 8 * 1024 * 1024,
                  let image = UIImage(contentsOfFile: url.path), image.size.width > 0, image.size.width <= 4096 else { continue }
            let format = UIGraphicsImageRendererFormat(); format.opaque = true; format.scale = 1
            let flat = UIGraphicsImageRenderer(size: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale), format: format).image { ctx in
                UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: ctx.format.bounds.size))
                image.draw(in: CGRect(origin: .zero, size: ctx.format.bounds.size))
            }
            if let png = flat.pngData() { try png.write(to: url, options: .atomic) }
        }
    }
}

enum PersonalCertificateSigner {
    struct Result {
        let url: URL
        let bundleIdentifierChanged: Bool
        let verification: PersonalProfileVerification
        var installed = false
        var installError: String? = nil
    }
    /// Extract and apply every non-signing edit. Shared by signed and configuration-only export.
    private static func prepare(ipa: URL, stage: URL, options: PersonalProjectOptions, applyBundleID: Bool = true) throws -> (root: URL, app: URL, info: [String: Any]) {
        let fm = FileManager.default
        let root = stage.appendingPathComponent("archive", isDirectory: true)
        try IPAEditorService.run("extract", input: ipa, output: root)
        let app = try IPAEditorService.app(in: root)
        if let overlay = options.bundleOverlay, !overlay.isEmpty, let blobs = options.bundleBlobs, let original = options.bundleOriginal {
            try BundleStagingApplier.apply(overlay, blobs: blobs, original: original, to: app)
        }
        let originalInfo = try IPAEditorService.info(in: app)
        var info = originalInfo
        if let name = options.displayName {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100 else {
                throw SideloadError.message("اكتب اسم تطبيق صالح.")
            }
            info["CFBundleDisplayName"] = name; info["CFBundleName"] = name
        }
        if applyBundleID, let id = options.bundleID {
            guard IPAEditorService.validBundleID(id) else { throw SideloadError.message("معرّف التطبيق غير صالح.") }
            info["CFBundleIdentifier"] = id
        }
        if let version = options.version {
            guard !version.isEmpty, version.count <= 64 else { throw SideloadError.message("رقم الإصدار غير صالح.") }
            info["CFBundleShortVersionString"] = version
        }
        switch options.gameMode {
        case .keep: break
        case .on: info["GCSupportsGameMode"] = true
        case .off: info["GCSupportsGameMode"] = false
        }
        if options.fileSharing { info["UIFileSharingEnabled"] = true; info["LSSupportsOpeningDocumentsInPlace"] = true }
        if options.removeURLSchemes { info.removeValue(forKey: "CFBundleURLTypes") }
        if let minimum = options.minimumOS, !minimum.isEmpty {
            guard minimum.range(of: #"^[0-9]{1,2}(\.[0-9]{1,2}){0,2}$"#, options: .regularExpression) != nil else {
                throw SideloadError.message("اكتب إصدار iOS صالح، مثل 15.0.")
            }
            info["MinimumOSVersion"] = minimum
        }
        if options.removeWatchApp {
            let watch = app.appendingPathComponent("Watch", isDirectory: true)
            if fm.fileExists(atPath: watch.path) { try fm.removeItem(at: watch) }
        }
        if options.removeEmbeddedProfile {
            let embedded = app.appendingPathComponent("embedded.mobileprovision")
            if fm.fileExists(atPath: embedded.path) { try fm.removeItem(at: embedded) }
        }
        if options.fixWhiteIcon { try PersonalIconFixer.flattenAlpha(app: app, info: info) }
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
        if options.displayName != nil {
            for language in try fm.contentsOfDirectory(at: app, includingPropertiesForKeys: nil) where language.pathExtension == "lproj" {
                let strings = language.appendingPathComponent("InfoPlist.strings")
                guard let size = try? strings.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
                      let data = try? Data(contentsOf: strings),
                      var localized = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { continue }
                localized.removeValue(forKey: "CFBundleDisplayName"); localized.removeValue(forKey: "CFBundleName")
                try PropertyListSerialization.data(fromPropertyList: localized, format: .binary, options: 0).write(to: strings, options: .atomic)
            }
        }
        if !options.injections.isEmpty {
            try IPAEditorService.run("inject_plan", input: app, newFirst: options.newTweaksFirst, injections: options.injections, order: options.injectionOrder, useLoader: options.useLoader)
        } else if !options.libraries.isEmpty {
            try IPAEditorService.run(options.useLoader ? "inject_loader" : "inject", input: app, executable: info["CFBundleExecutable"] as? String, libraries: options.libraries, newFirst: options.newTweaksFirst)
        }
        return (root, app, info)
    }
    /// Configuration-only export: same edits, NO signing. Caller must label the result unsigned.
    static func exportConfigurationOnly(ipa: URL, options: PersonalProjectOptions) throws -> URL {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("personal-config-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        defer { try? fm.removeItem(at: stage) }
        let (root, app, info) = try prepare(ipa: ipa, stage: stage, options: options)
        try IPAEditorService.run("validate", input: app.appendingPathComponent(info["CFBundleExecutable"] as! String))
        return try pack(root: root, options: options, suffix: "-unsigned")
    }
    private static func pack(root: URL, options: PersonalProjectOptions, suffix: String = "") throws -> URL {
        let fm = FileManager.default
        let exports = fm.temporaryDirectory.appendingPathComponent("Mirsa-Signed-\(UUID().uuidString)", isDirectory: true)
        var filename = options.outputFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        for known in [".ipa", ".tipa"] where filename.lowercased().hasSuffix(known) { filename = String(filename.dropLast(known.count)) }
        guard !filename.isEmpty, filename.count <= 120, !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              filename != ".", filename != ".." else { throw SideloadError.message("اسم ملف التصدير غير صالح.") }
        try fm.createDirectory(at: exports, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        let ext = options.exportExtension == "tipa" ? "tipa" : "ipa"
        let output = exports.appendingPathComponent(filename + suffix + "." + ext)
        do { try IPAEditorService.run("pack", input: root, output: output) }
        catch { try? fm.removeItem(at: exports); throw error }
        return output
    }
    private static func customEntitlementsPath(_ options: PersonalProjectOptions, stage: URL) throws -> String {
        guard let data = options.customEntitlements else { return "" }
        guard data.count <= 64 * 1024,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil), plist is [String: Any] else {
            throw SideloadError.message("ملف Entitlements غير صالح.")
        }
        let url = stage.appendingPathComponent("custom.entitlements")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url.path
    }
    static func sign(ipa: URL, material: PersonalIdentityVault.Material, pairingPath: String, options: PersonalProjectOptions = .init(), cachedUDID: String? = nil, install: Bool = false,
                     control: PersonalSigningControl = PersonalSigningControl(),
                     progress: @escaping (PersonalSigningEvent) -> Void = { _ in }) throws -> Result {
        try control.checkpoint()
        progress(PersonalSigningEvent(stage: .preparing))
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("personal-sign-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.complete])
        defer { try? fm.removeItem(at: stage) }
        let (root, app, info) = try prepare(ipa: ipa, stage: stage, options: options, applyBundleID: false)
        // Reject FairPlay/encrypted code, including embedded libraries, before signing.
        let executable = app.appendingPathComponent(info["CFBundleExecutable"] as! String)
        try IPAEditorService.run("validate", input: executable)
        let profile = stage.appendingPathComponent("profile.mobileprovision")
        try material.profile.write(to: profile, options: [.atomic, .completeFileProtection])
        let (key, certificate) = try PersonalIdentityVault.identity(material)
        let request: [String: Any] = ["operation": "personal_sign", "input": app.path,
                                      "profile": profile.path, "private_key": key.base64EncodedString(),
                                      "certificate": certificate.base64EncodedString(),
                                      "pairing_path": pairingPath,
                                      "cached_only": cachedUDID != nil,
                                      "cached_udid": cachedUDID ?? "",
                                      "bundle_id": options.bundleID ?? "",
                                      "remove_extensions": options.removeExtensions,
                                      "remove_watch": options.removeWatchApp,
                                      "remove_app_clips": options.removeAppClips,
                                      "strict_profile": options.strictProfile,
                                      "custom_entitlements_path": try customEntitlementsPath(options, stage: stage),
                                      "profiles": try options.additionalProfiles.enumerated().map { index, data in
                                          let url = stage.appendingPathComponent("profile-extra-\(index).mobileprovision")
                                          try data.write(to: url, options: [.atomic, .completeFileProtection])
                                          return url.path
                                      }]
        try control.checkpoint()
        let callback = PersonalSigningCallback(control: control, report: progress)
        let context = Unmanaged.passRetained(callback).toOpaque()
        defer { Unmanaged<PersonalSigningCallback>.fromOpaque(context).release() }
        let bytes = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(data: bytes, encoding: .utf8),
              let response = text.withCString({ request in
                  personalEditorRunProgress(request, { context, completed, total in
                      guard let context else { return 0 }
                      let box = Unmanaged<PersonalSigningCallback>.fromOpaque(context).takeUnretainedValue()
                      guard !box.control.isCancelled else { return 0 }
                      box.report(.signing(completed: completed, total: total))
                      return 1
                  }, context)
              }) else {
            throw SideloadError.message("Personal signer did not respond.")
        }
        defer { al_string_free(response) }
        let data = Data(String(cString: response).utf8)
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard result?["ok"] as? Bool == true else {
            throw SideloadError.message(result?["error"] as? String ?? "Personal signing failed.")
        }
        // Export artifact contains signed application and public profile only,
        // never P12, password or private key.
        try control.checkpoint()
        progress(PersonalSigningEvent(stage: .packaging))
        let output = try pack(root: root, options: options)
        let signedInfo = try IPAEditorService.info(in: app)
        var r = Result(url: output, bundleIdentifierChanged:
            (signedInfo["CFBundleIdentifier"] as? String) != (info["CFBundleIdentifier"] as? String),
            verification: PersonalProfileVerification.parse(result ?? [:]))
        if install {
            // Real device install of the just-signed bundle. The packed IPA is kept on failure.
            do {
                try control.checkpoint()
                progress(PersonalSigningEvent(stage: .connecting))
                _ = try SideloadService.installSigned(appPath: app.path) { fraction, stage in
                    // Callback 100 can precede the backend's final success/error response.
                    if let event = PersonalSigningEvent.installation(fraction, stage: stage) { progress(event) }
                }
                r.installed = true
            }
            catch { r.installError = error.localizedDescription }
        }
        return r
    }
}

struct PersonalCertificateView: View {
    var onSaved: (() -> Void)? = nil
    @State private var p12: Data?
    @State private var profile: Data?
    @State private var password = ""
    @State private var showPassword = false
    @State private var p12Name = ""
    @State private var profileName = ""
    @State private var picker: ImportKind?
    @State private var message: String?
    @State private var saving = false
    @State private var latest: PersonalIdentityVault.SavedIdentity?
    @State private var count = 0
    @State private var phase = 0.0
    @FocusState private var passwordFocused: Bool
    private enum ImportKind: String, Identifiable { case p12, profile; var id: String { rawValue } }

    private var canSave: Bool { p12 != nil && profile != nil && !saving }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(personalText("Sign apps with a certificate", "توقيع التطبيقات بشهادة"), systemImage: "signature")
                .font(.title3.bold())
            Text(personalText("Use your own P12 and provisioning profile. Apple ID and Container signing stay unchanged. Everything is signed locally.",
                              "استخدم شهادة P12 وملف mobileprovision تبعك. حساب Apple ID والحاوية بيضلوا متل ما هنن. التوقيع بيصير على جهازك."))
                .font(.footnote).foregroundStyle(.secondary)
            fileCard(kind: .p12, icon: "person.badge.key.fill", title: personalText("Import P12", "استيراد P12"), name: p12Name, done: p12 != nil)
            passwordField
            fileCard(kind: .profile, icon: "doc.badge.gearshape.fill", title: personalText("Import mobileprovision", "استيراد mobileprovision"), name: profileName, done: profile != nil)
            Button { save() } label: {
                HStack(spacing: 8) {
                    if saving { ProgressView() } else { Image(systemName: "lock.shield.fill") }
                    Text(personalText("Save certificate securely", "حفظ الشهادة بأمان")).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(LinearGradient(colors: [Color.green, Color.teal], startPoint: .leading, endPoint: .trailing)
                    .opacity(canSave ? 1 : 0.3), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }.buttonStyle(.plain).disabled(!canSave)
            if let latest { savedCard(latest) }
            Text(personalText("The IPA must be unencrypted. Each retained app or extension needs a matching Development or Ad Hoc profile that includes the connected device. Device authorization is checked through pairing when signing.",
                              "لازم ملف IPA يكون غير مشفّر. كل تطبيق أو إضافة بتحتفظ فيها بدها بروفايل Development أو Ad Hoc مطابق ومضاف فيه الجهاز المتصل. تطابق الجهاز بينفحص عبر الاقتران وقت التوقيع."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("personal-certificate-signing-note")
            if let message { Text(message).font(.footnote).textSelection(.enabled) }
        }
        .padding(18).appsGlass(cornerRadius: 28)
        .environment(\.layoutDirection, .leftToRight)
        .disabled(saving)
        .sheet(item: $picker) { kind in
            DocumentPickerView(allowedContentTypes: [UTType(filenameExtension: kind == .profile ? "mobileprovision" : kind.rawValue) ?? .data]) { url in
                receive(url, kind: kind)
            }
        }
        .task {
            reloadSaved()
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { phase = 360 }
        }
        .onDisappear { password = ""; p12 = nil; profile = nil; p12Name = ""; profileName = "" }
    }

    private func border(_ active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(active
                ? AnyShapeStyle(AngularGradient(colors: [.green, .teal, .purple, .green], center: .center, angle: .degrees(phase)))
                : AnyShapeStyle(Color.white.opacity(0.14)), lineWidth: active ? 1.8 : 1)
    }
    private func fileCard(kind: ImportKind, icon: String, title: String, name: String, done: Bool) -> some View {
        Button { picker = kind } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(done ? Color.green : Color.blue).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(done ? name : personalText("Tap to choose a file", "اضغط لاختيار ملف")).font(.caption)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Image(systemName: done ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(done ? Color.green : Color.secondary)
            }
            .padding(14).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(border(done))
        }.buttonStyle(.plain)
    }
    private var passwordField: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(.secondary)
            Group {
                if showPassword {
                    TextField("", text: $password, prompt: Text(personalText("P12 password", "كلمة سر P12")).foregroundColor(.secondary))
                } else {
                    SecureField("", text: $password, prompt: Text(personalText("P12 password", "كلمة سر P12")).foregroundColor(.secondary))
                }
            }
            .focused($passwordFocused).textContentType(.password)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            Button { showPassword.toggle() } label: {
                Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill").foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(14).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(border(passwordFocused))
    }
    private func savedCard(_ item: PersonalIdentityVault.SavedIdentity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(personalText("Selected certificate", "الشهادة المحددة") + (count > 1 ? " (\(count))" : ""), systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(item.verification.isVerified ? Color.green : Color.orange)
            Text(item.name).font(.headline).lineLimit(2)
            Text("تطابق الجهاز لسا مو مفحوص. بينفحص وقت التوقيع عبر الاتصال بالجهاز.").font(.caption).foregroundStyle(.secondary)
            if !item.verification.isVerified {
                Label(item.verification.warningText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Team ID: " + item.teamID).font(.caption).foregroundStyle(.secondary)
            Text(item.bundleID).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if !item.profileType.isEmpty { Text(item.profileType).font(.caption2).foregroundStyle(.secondary) }
            if let e = item.expiry {
                Text(personalText("Local expiry date: ", "تاريخ الانتهاء المحلي: ") + e.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background((item.verification.isVerified ? Color.green : Color.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    private func reloadSaved() {
        do {
            let all = try PersonalIdentityVault.savedIdentities()
            let id = try PersonalIdentityVault.selectedID()
            count = all.count
            latest = all.first { $0.id == id } ?? all.first
        } catch { message = error.localizedDescription }
    }
    private func receive(_ url: URL, kind: ImportKind) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            let limit = kind == .profile ? 256 * 1024 : 1024 * 1024
            guard size.isRegularFile == true, let bytes = size.fileSize, bytes > 0, bytes <= limit else {
                throw SideloadError.message(personalText("File is empty, not a regular file, or too large.", "الملف فاضي أو مو عادي أو كبير كتير."))
            }
            message = nil
            switch kind {
            case .p12: p12 = try Data(contentsOf: url); p12Name = url.lastPathComponent; password = ""
            case .profile: profile = try Data(contentsOf: url); profileName = url.lastPathComponent
            }
        } catch { message = error.localizedDescription }
    }
    private func save() {
        guard let p12, let profile else { return }
        saving = true; message = nil
        let material = PersonalIdentityVault.Material(p12: p12, password: password, profile: profile)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    _ = try PersonalIdentityVault.identity(material)
                    try PersonalIdentityVault.save(material)
                }.value
                self.p12 = nil; self.profile = nil; password = ""; p12Name = ""; profileName = ""
                reloadSaved()
                message = personalText("Saved. Profile compatibility is checked when signing.", "انحفظت. تطابق الملف بينفحص وقت التوقيع.")
                onSaved?()
            } catch { message = error.localizedDescription }
            saving = false
        }
    }
}
struct PersonalSignedShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
