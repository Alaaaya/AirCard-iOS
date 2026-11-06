import SwiftUI
import UniformTypeIdentifiers
import Security
import AirliftFFI

@_silgen_name("al_ipa_editor_run")
private func personalEditorRun(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

// Separate from Apple ID storage and its handover/export/wipe operations.
enum PersonalIdentityVault {
    private static let service = "com.alaa.mirsa.personal-signing"
    struct Material: Codable { let p12: Data; let password: String; let profile: Data }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "identity"]
    }
    static func load() throws -> Material? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw SideloadError.message("Unlock your iPhone to access your signing identity.")
        }
        return try JSONDecoder().decode(Material.self, from: data)
    }
    static func save(_ material: Material) throws {
        let data = try JSONEncoder().encode(material)
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
        guard status == errSecSuccess else { throw SideloadError.message("Could not save identity securely in Keychain.") }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SideloadError.message("Could not remove identity from Keychain.")
        }
    }
    static func identity(_ material: Material) throws -> (Data, Data) {
        var items: CFArray?
        let status = SecPKCS12Import(material.p12 as CFData,
                                    [kSecImportExportPassphrase as String: material.password] as CFDictionary, &items)
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]], entries.count == 1,
              let raw = entries[0][kSecImportItemIdentity as String] else {
            throw SideloadError.message("Cannot open P12. Check its password and make sure it contains one signing certificate and its private key.")
        }
        guard CFGetTypeID(raw as CFTypeRef) == SecIdentityGetTypeID() else {
            throw SideloadError.message("P12 does not contain a signing identity.")
        }
        let identity = raw as! SecIdentity
        var key: SecKey?
        var cert: SecCertificate?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess,
              SecIdentityCopyCertificate(identity, &cert) == errSecSuccess,
              let key, let cert,
              let attrs = SecKeyCopyAttributes(key) as? [String: Any],
              attrs[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeRSA as String,
              let exported = SecKeyCopyExternalRepresentation(key, nil) else {
            throw SideloadError.message("Use an exportable RSA Apple signing identity.")
        }
        return (exported as Data, SecCertificateCopyData(cert) as Data)
    }
}

enum PersonalCertificateSigner {
    static func sign(ipa: URL, material: PersonalIdentityVault.Material) throws -> URL {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("personal-sign-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.complete])
        defer { try? fm.removeItem(at: stage) }
        let root = stage.appendingPathComponent("archive", isDirectory: true)
        try IPAEditorService.run("extract", input: ipa, output: root)
        let app = try IPAEditorService.app(in: root)
        let info = try IPAEditorService.info(in: app)
        // Reject FairPlay/encrypted code, including embedded libraries, before signing.
        let executable = app.appendingPathComponent(info["CFBundleExecutable"] as! String)
        try IPAEditorService.run("validate", input: executable)
        let profile = stage.appendingPathComponent("profile.mobileprovision")
        try material.profile.write(to: profile, options: [.atomic, .completeFileProtection])
        let (key, certificate) = try PersonalIdentityVault.identity(material)
        let request: [String: Any] = ["operation": "personal_sign", "input": app.path,
                                      "profile": profile.path, "private_key": key.base64EncodedString(),
                                      "certificate": certificate.base64EncodedString()]
        let bytes = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(data: bytes, encoding: .utf8),
              let response = text.withCString({ personalEditorRun($0) }) else {
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
        let exports = fm.temporaryDirectory.appendingPathComponent("Mirsa-Signed-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.complete])
        let output = exports.appendingPathComponent("Mirsa-Signed.ipa")
        do { try IPAEditorService.run("pack", input: root, output: output) }
        catch { try? fm.removeItem(at: exports); throw error }
        return output
    }
}

struct PersonalCertificateView: View {
    var initialIPA: URL? = nil
    @State private var p12: Data?
    @State private var profile: Data?
    @State private var password = ""
    @State private var p12Name = ""
    @State private var profileName = ""
    @State private var ipa: URL?
    @State private var picker: ImportKind?
    @State private var saved = false
    @State private var busy = false
    @State private var message: String?
    @State private var output: URL?
    @State private var sharing = false
    @State private var confirmRemove = false
    private enum ImportKind: String, Identifiable { case p12, profile; var id: String { rawValue } }
    private func text(_ en: String, _ ar: String) -> String { L.isArabic ? ar : en }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(text("Sign apps with a certificate", "توقيع التطبيقات بشهادة"), systemImage: "signature")
                .font(.title3.bold())
            Text(text("Use your own P12 and provisioning profile. Apple ID and Container signing stay unchanged. Everything is signed locally.",
                      "استخدم شهادة P12 وملف mobileprovision تبعك. حساب Apple ID والحاوية بيضلوا متل ما هنن. التوقيع بيصير على جهازك."))
                .font(.footnote).foregroundStyle(.secondary)
            if saved {
                Label(text("Identity saved in Keychain", "الشهادة محفوظة بأمان"), systemImage: "lock.shield")
                Text(text("Certificate, expiry and profile compatibility are checked when signing.",
                          "تطابق الشهادة والملف وتاريخ الصلاحية بينفحصوا وقت التوقيع."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if initialIPA == nil {
                Button { picker = .p12 } label: {
                    Label(p12Name.isEmpty ? text("Import P12", "استيراد P12") : p12Name, systemImage: "person.badge.key")
                }
                if p12 != nil {
                    SecureField(text("P12 password", "كلمة سر P12"), text: $password)
                        .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .textFieldStyle(.roundedBorder)
                }
                Button { picker = .profile } label: {
                    Label(profileName.isEmpty ? text("Import mobileprovision", "استيراد mobileprovision") : profileName, systemImage: "doc.badge.gearshape")
                }
                if p12 != nil || profile != nil {
                    Button(text("Save identity securely", "حفظ الشهادة بأمان")) { save() }
                        .disabled(p12 == nil || profile == nil)
                }
            } else {
                Label(ipa?.lastPathComponent ?? text("Library app", "تطبيق المكتبة"), systemImage: "app")
                if !saved {
                    Text(text("Save your certificate in certificate settings first.", "احفظ شهادتك من إعدادات الشهادة بالأول."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button { sign() } label: {
                    HStack {
                        if busy { ProgressView() }
                        Text(text("Sign and export IPA", "توقيع وتصدير IPA")).fontWeight(.semibold)
                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!saved || ipa == nil || busy || p12 != nil || profile != nil)
                if let output {
                    Button { sharing = true } label: { Label(text("Export signed IPA", "تصدير IPA الموقّع"), systemImage: "square.and.arrow.up") }
                    Text(text("Export to Files or a compatible installer. Exporting does not install the app. Your device must be included in the profile; iOS checks revocation and trust at installation.",
                              "احفظه بالملفات أو افتحه بمثبّت بيدعمه. التصدير لحاله ما بيثبّت التطبيق. لازم جهازك يكون ضمن الملف، وiOS بيتأكد من صلاحية الشهادة وقت التثبيت."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(output.lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(text("Currently supports unencrypted apps without extensions, Watch apps or App Clips. A matching development, Ad Hoc or enterprise profile is required.",
                      "حالياً بيدعم التطبيقات غير المشفّرة وبدون إضافات أو تطبيق ساعة أو App Clips. بدك ملف تطوير أو Ad Hoc أو مؤسسات مطابق للتطبيق."))
                .font(.caption).foregroundStyle(.secondary)
            if saved && initialIPA == nil {
                Button(text("Remove saved identity", "حذف الشهادة المحفوظة"), role: .destructive) { confirmRemove = true }
            }
            if let message { Text(message).font(.footnote).textSelection(.enabled) }
        }
        .padding(18).appsGlass(cornerRadius: 24)
        .environment(\.layoutDirection, .leftToRight)
        .disabled(busy)
        .sheet(item: $picker) { kind in
            DocumentPickerView(allowedContentTypes: [UTType(filenameExtension: kind == .profile ? "mobileprovision" : kind.rawValue) ?? .data]) { url in
                receive(url, kind: kind)
            }
        }
        .sheet(isPresented: $sharing) {
            if let output { PersonalSignedShare(url: output) }
        }
        .confirmationDialog(text("Remove only the saved personal identity?", "حذف الشهادة الشخصية المحفوظة بس؟"), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(text("Remove", "حذف"), role: .destructive) {
                do { try PersonalIdentityVault.remove(); saved = false; clearOutput() }
                catch { message = error.localizedDescription }
            }
        }
        .task {
            if let initialIPA, ipa == nil { receiveLibraryIPA(initialIPA) }
            do { saved = try PersonalIdentityVault.load() != nil }
            catch { message = error.localizedDescription }
        }
        .onDisappear {
            password = ""; p12 = nil; profile = nil; p12Name = ""; profileName = ""
            // Do not remove an artifact while the share extension is reading it.
            if !busy && !sharing { clearOutput(); clearIPA() }
        }
    }

    private func receive(_ url: URL, kind: ImportKind) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            let limit = kind == .profile ? 256 * 1024 : 1024 * 1024
            guard size.isRegularFile == true, let count = size.fileSize, count > 0, count <= limit else {
                throw SideloadError.message("File is empty, not a regular file, or exceeds the size limit.")
            }
            clearOutput(); message = nil
            switch kind {
            case .p12: p12 = try Data(contentsOf: url); p12Name = url.lastPathComponent; password = ""
            case .profile: profile = try Data(contentsOf: url); profileName = url.lastPathComponent
            }
        } catch { message = error.localizedDescription }
    }
    // Only called with a selected personal-library item, never a file picker.
    private func receiveLibraryIPA(_ url: URL) {
        do {
            clearIPA()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("personal-input-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            let dest = folder.appendingPathComponent("Input.ipa")
            do { try FileManager.default.copyItem(at: url, to: dest); ipa = dest }
            catch { try? FileManager.default.removeItem(at: folder); throw error }
        } catch { message = error.localizedDescription }
    }
    private func save() {
        guard let p12, let profile else { return }
        do {
            let material = PersonalIdentityVault.Material(p12: p12, password: password, profile: profile)
            _ = try PersonalIdentityVault.identity(material)
            try PersonalIdentityVault.save(material)
            self.p12 = nil; self.profile = nil; password = ""; p12Name = ""; profileName = ""
            saved = true; message = text("Saved. Profile compatibility will be checked before signing.", "انحفظت. تطابق الملف بينفحص قبل التوقيع.")
        } catch { message = error.localizedDescription }
    }
    private func sign() {
        guard let ipa else { return }
        busy = true; message = nil; clearOutput()
        Task {
            do {
                guard let material = try PersonalIdentityVault.load() else { throw SideloadError.message("Import a personal signing identity first.") }
                let signed = try await Task.detached(priority: .userInitiated) {
                    try PersonalCertificateSigner.sign(ipa: ipa, material: material)
                }.value
                output = signed
                do { try await PersonalAppsLibrary.shared.add(signed, signed: true) }
                catch { message = text("Signed, but saving to the personal library failed. Export remains available.", "تم التوقيع بس الحفظ بالمكتبة فشل. التصدير لسا متاح."); busy = false; return }
                message = text("Signed locally. Ready to export.", "تم التوقيع على جهازك. جاهز للتصدير.")
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func clearOutput() {
        if let output { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        output = nil
    }
    private func clearIPA() {
        if let ipa { try? FileManager.default.removeItem(at: ipa.deletingLastPathComponent()) }
        ipa = nil
    }
}
private struct PersonalSignedShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
