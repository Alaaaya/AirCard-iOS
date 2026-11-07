import Foundation
import UIKit

enum MirsaInstallMode {
    static let key = "mirsa.install.mode"
    static var ownCertificate: Bool { UserDefaults.standard.string(forKey: key) == "certificate" }
}
final class OTANoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor enum CertificateOTA {
    static let endpoint = URL(string: WebBackendConfig.defaultProject + "/functions/v1/certificate-ota")!
    static func install(source: URL) async throws {
        guard let identity = PersonalIdentityVault.savedIdentities().first else {
            throw SideloadError.message(personalText("Import your certificate first.", "استورد شهادتك بالأول."))
        }
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("ota-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage.appendingPathComponent("Payload"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let app = stage.appendingPathComponent("Payload/Mirsa.app", isDirectory: true)
        try fm.copyItem(at: source, to: app)
        let input = stage.appendingPathComponent("input.ipa")
        try await Task.detached { try IPAEditorService.run("pack", input: stage, output: input) }.value
        let material = identity.material
        let pairing = PairingController.pairingFilePath()
        var options = PersonalProjectOptions()
        options.strictProfile = true // Self-install requires a profile that actually covers this identity.
        let signed = try await Task.detached {
            try PersonalCertificateSigner.sign(ipa: input, material: material, pairingPath: pairing, options: options)
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
        let metadata: [String: Any] = ["bundleID": bundleID, "version": version, "title": "Mirsa", "bytes": bytes.count]
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
