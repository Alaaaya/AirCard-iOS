import Foundation
import UIKit
import Security

enum MirsaInstallMode {
    static let key = "mirsa.install.mode"
    static var ownCertificate: Bool { UserDefaults.standard.string(forKey: key) == "certificate" }
}
final class OTANoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor enum CertificateOTA {
    static let endpoint = URL(string: WebBackendConfig.defaultProject + "/functions/v1/certificate-ota")!
    static func install(source: URL, material explicitMaterial: PersonalIdentityVault.Material? = nil, options explicitOptions: PersonalProjectOptions? = nil) async throws {
        let selectedMaterial: PersonalIdentityVault.Material
        if let explicitMaterial { selectedMaterial = explicitMaterial }
        else if let identity = PersonalIdentityVault.savedIdentities().first { selectedMaterial = identity.material }
        else { throw SideloadError.message(personalText("Import your certificate first.", "استورد شهادتك بالأول.")) }
        let device = try OwnCertificateDevice.require()
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("ota-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage.appendingPathComponent("Payload"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let app = stage.appendingPathComponent("Payload/Mirsa.app", isDirectory: true)
        try fm.copyItem(at: source, to: app)
        let input = stage.appendingPathComponent("input.ipa")
        try await Task.detached { try IPAEditorService.run("pack", input: stage, output: input) }.value
        let material = selectedMaterial

        var options = explicitOptions ?? PersonalProjectOptions()
        if explicitOptions == nil { options.strictProfile = true }
        _ = options.strictProfile // Self-install requires a profile that actually covers this identity.
        let signed = try await Task.detached {
            try PersonalCertificateSigner.sign(ipa: input, material: material, pairingPath: "", options: options, cachedUDID: device)
        }.value
        defer { try? fm.removeItem(at: signed.url.deletingLastPathComponent()) }
        let info = try IPAEditorService.info(in: app)
        guard let bundleID = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleVersion"] as? String else { throw SideloadError.message("Missing application identity.") }
        let bytes = try Data(contentsOf: signed.url, options: .mappedIfSafe)
        guard bytes.count <= 30 * 1024 * 1024 else { throw SideloadError.message("OTA upload limit is 30 MB.") }
        let auth = DiscoveryAuthClient(projectURL: URL(string: WebBackendConfig.defaultProject)!,
            publishableKey: WebBackendConfig.defaultPublishableKey, store: KeychainSessionStore(), http: SafeMetadataHTTP())
        let token = try await auth.token(forceRefresh: false)
        let metadata: [String: Any] = ["bundleID": bundleID, "version": version, "title": (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID, "bytes": bytes.count]
        let data = try JSONSerialization.data(withJSONObject: metadata)
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.setValue(String(decoding: data, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: allowed), forHTTPHeaderField: "x-mirsa-metadata")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: OTANoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (response, http) = try await session.upload(for: request, from: bytes)
        guard (http as? HTTPURLResponse)?.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let manifest = result["manifestURL"] as? String,
              let url = URL(string: manifest), url.scheme == "https", url.host == endpoint.host,
              url.path == endpoint.path, url.user == nil, url.password == nil else {
            throw SideloadError.message(personalText("Temporary OTA upload failed or quota reached.", "رفع التثبيت المؤقت فشل أو وصل للحد المسموح."))
        }
        var install = URLComponents()
        install.scheme = "itms-services"
        install.queryItems = [.init(name: "action", value: "download-manifest"), .init(name: "url", value: manifest)]
        guard let target = install.url, await UIApplication.shared.open(target) else {
            throw SideloadError.message(personalText("iOS could not open OTA installation.", "iOS ما قدر يفتح تثبيت OTA."))
        }
        // Opening the installer is not evidence of successful device installation.
    }
}

enum OwnCertificateDevice {
    static let message = "إعداد الجهاز مطلوب مرة واحدة. فعّل VPN والاقتران واضغط قراءة الجهاز هون، وبعد نجاح القراءة طفي VPN وثبّت بشهادتك."
    static var query: [String: Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"mirsa.owncert.realdevice.v1", kSecAttrAccount as String:"device", kSecAttrSynchronizable as String:false]
    }
    static func clear() { SecItemDelete(query as CFDictionary); try? FileManager.default.removeItem(at:bindingFile) }
    static var bindingFile: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("owncert-install-binding")
    }
    static func validRecord(_ value: [String:String], vendor: String?, installation: String?) -> Bool {
        guard let vendor, !vendor.isEmpty, let installation, !installation.isEmpty else { return false }
        guard value["binding"] == vendor, value["installation"] == installation, let id=value["udid"] else { return false }
        return id.range(of:"^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})$",options:.regularExpression) != nil
    }
    static func require() throws -> String {
        var q=query; q[kSecReturnData as String]=true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess, let data=item as? Data,
              let value=try? JSONDecoder().decode([String:String].self,from:data),
              validRecord(value, vendor:UIDevice.current.identifierForVendor?.uuidString, installation:try? String(contentsOf:bindingFile,encoding:.utf8)),
              let id=value["udid"], !id.isEmpty else {
            clear(); throw SideloadError.message(message)
        }
        return id
    }
    @MainActor static func setup() async throws {
        clear()
        let path=PairingController.pairingFilePath()
        let output=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:output) }
        try await Task.detached {
            try IPAEditorService.run("read_device_once",input:URL(fileURLWithPath:path),output:output)
        }.value
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:output.path)
        guard let binding=UIDevice.current.identifierForVendor?.uuidString else { throw SideloadError.message(message) }
        let udid=try String(contentsOf:output,encoding:.utf8)
        let installation=UUID().uuidString
        try FileManager.default.createDirectory(at:bindingFile.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(installation.utf8).write(to:bindingFile,options:[.atomic,.completeFileProtection])
        var file=bindingFile
        var resource=URLResourceValues(); resource.isExcludedFromBackup=true
        try file.setResourceValues(resource)
        guard validRecord(["udid":udid,"binding":binding,"installation":installation],vendor:binding,installation:installation) else { clear(); throw SideloadError.message(message) }
        let data=try JSONEncoder().encode(["udid":udid,"binding":binding,"installation":installation])
        var q=query; q[kSecValueData as String]=data
        q[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else { throw SideloadError.message(message) }
    }
}

import SwiftUI
struct OwnCertificateDeviceSetup: View {
    @State private var status = OwnCertificateDevice.message
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading) {
            Text(status).font(.caption)
            Button("قراءة الجهاز مرة واحدة / إعادة المحاولة") {
                busy = true
                Task {
                    do {
                        try await OwnCertificateDevice.setup()
                        status = "تم حفظ الجهاز بأمان. فيك تطفي VPN وتثبّت بشهادتك."
                    } catch { status = error.localizedDescription }
                    busy = false
                }
            }.disabled(busy)
            Button("مسح بيانات الجهاز المحفوظة", role: .destructive) {
                OwnCertificateDevice.clear()
                status = OwnCertificateDevice.message
            }.disabled(busy)
        }
    }
}
