import Foundation
import Security
import AirliftFFI

// MARK: - Keychain

/// Minimal generic-password Keychain wrapper. Everything the sideloader
/// persists (Apple ID, password, anisette state, certificate private key)
/// lives here — never in UserDefaults or on disk.
enum Keychain {
    static let service = "com.aircard.sideloader"

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Every item this app keeps (Apple ID login, signing key, session), for
    /// handing over from Mirsa Setup to the Mirsa it installs.
    static func exportAll() -> [String: String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [:] }
        var d: [String: String] = [:]
        for it in items {
            if let k = it[kSecAttrAccount as String] as? String,
               let v = it[kSecValueData as String] as? Data,
               let sv = String(data: v, encoding: .utf8) { d[k] = sv }
        }
        return d
    }

    static func importAll(_ d: [String: String]) {
        for (k, v) in d { set(k, v) }
    }

    static func wipe() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Prompts coming from Rust

/// A question Rust needs answered by the user while it is blocked
/// (2FA code, or which certificate to revoke when the account is at its limit).
struct SideloadPrompt: Identifiable {
    enum Kind { case twoFactor, maxCerts }
    struct Cert: Identifiable, Hashable { let name: String; let machine: String; let serial: String; var id: String { serial } }
    struct Phone: Identifiable, Hashable { let id: Int; let number: String }

    let id = UUID()
    let kind: Kind
    let sms: Bool
    let lastError: String?
    let phones: [Phone]
    let certs: [Cert]
}

/// Bridges a blocking Rust callback to a SwiftUI sheet.
final class PromptBridge {
    static let shared = PromptBridge()
    var present: ((SideloadPrompt) -> Void)?
    private var answer: String?
    private let sema = DispatchSemaphore(value: 0)

    /// Called on a Rust worker thread. Blocks until `respond` is called.
    func ask(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let kind: SideloadPrompt.Kind = (obj["kind"] as? String) == "max_certs" ? .maxCerts : .twoFactor
        let phones = ((obj["numbers"] as? [[String: Any]]) ?? []).compactMap { n -> SideloadPrompt.Phone? in
            guard let id = n["id"] as? Int else { return nil }
            return .init(id: id, number: n["numberWithDialCode"] as? String ?? "")
        }
        let certs = ((obj["certs"] as? [[String: Any]]) ?? []).map {
            SideloadPrompt.Cert(name: $0["name"] as? String ?? "", machine: $0["machine_name"] as? String ?? "", serial: $0["serial"] as? String ?? "")
        }
        let prompt = SideloadPrompt(kind: kind, sms: obj["sms"] as? Bool ?? false,
                                    lastError: obj["lastError"] as? String,
                                    phones: phones, certs: certs)
        answer = nil
        DispatchQueue.main.async { self.present?(prompt) }
        sema.wait()
        return answer
    }

    func respond(_ value: String?) {
        answer = value
        sema.signal()
    }
}

// MARK: - FFI wrapper

enum SideloadError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Thin, thread-safe wrapper over the `al_sl_*` / `al_container_*` FFI.
/// Every call blocks, so call from a background queue.
enum SideloadService {
    static func configure() {
        let store = ALKeyValueStore(
            ctx: nil,
            get: { _, key in
                guard let key, let v = Keychain.get("kv." + String(cString: key)) else { return nil }
                return strdup(v)
            },
            set: { _, key, value in
                guard let key else { return }
                let v = value.map { String(cString: $0) }
                Keychain.set("kv." + String(cString: key), v)
            }
        )
        _ = al_sl_set_storage(store)
    }

    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { al_string_free(p) }
        return String(cString: p)
    }

    private static func json(_ s: String?) -> [String: Any] {
        guard let s, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    static var isLoggedIn: Bool { al_sl_is_logged_in() == 1 }

    static func login(email: String, password: String) throws -> [String: Any] {
        var out: UnsafeMutablePointer<CChar>?
        var err: UnsafeMutablePointer<CChar>?
        let anisette = UserDefaults.standard.string(forKey: "apps.anisetteURL") ?? ""
        let rc = al_sl_login(email, password, anisette, { _, json in
            guard let json else { return nil }
            guard let a = PromptBridge.shared.ask(String(cString: json)) else { return nil }
            return strdup(a)
        }, nil, &out, &err)
        let o = take(out), e = take(err)
        if rc != 0 { throw SideloadError.message(e ?? "Sign-in failed") }
        return json(o)
    }

    /// PairingController is @MainActor; resolve the pairing path on the main thread
    /// so these blocking FFI calls can run from any context.
    private static func pairingPath() -> String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { PairingController.pairingFilePath() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { PairingController.pairingFilePath() }
        }
    }

    static func logout() { al_sl_logout() }

    static func accountInfo() throws -> [String: Any] {
        var out: UnsafeMutablePointer<CChar>?
        var err: UnsafeMutablePointer<CChar>?
        let rc = al_sl_account_info(&out, &err)
        let o = take(out), e = take(err)
        if rc != 0 { throw SideloadError.message(e ?? "Account info failed") }
        return json(o)
    }

    final class ProgressBox { let f: (Double, String) -> Void; init(_ f: @escaping (Double, String) -> Void) { self.f = f } }

    static func install(appPath: String, progress: @escaping (Double, String) -> Void) throws -> [String: Any] {
        var out: UnsafeMutablePointer<CChar>?
        var err: UnsafeMutablePointer<CChar>?
        let box = ProgressBox(progress)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(ctx).release() }
        // Breadcrumbs: if the app dies mid-install, the next launch can say where.
        UserDefaults.standard.set("Starting", forKey: "mirsa.install.stage")
        UserDefaults.standard.removeObject(forKey: "mirsa.install.lastLog")
        defer {
            UserDefaults.standard.removeObject(forKey: "mirsa.install.stage")
            UserDefaults.standard.removeObject(forKey: "mirsa.install.lastLog")
        }
        let rc = al_sl_install(pairingPath(), appPath, "iPhone", { ctx, f, stage in
            guard let ctx else { return }
            let b = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            let s = stage.map { String(cString: $0) } ?? ""
            UserDefaults.standard.set("\(s) (\(Int(f * 100))%)", forKey: "mirsa.install.stage")
            DispatchQueue.main.async { b.f(f, s) }
        }, { _, msg in
            guard let msg else { return }
            let line = String(cString: msg)
            UserDefaults.standard.set(line, forKey: "mirsa.install.lastLog")
            DispatchQueue.main.async { AppViewModel.sharedLogSink?(line) }
        }, ctx, &out, &err)
        let o = take(out), e = take(err)
        if rc != 0 { throw SideloadError.message(e ?? "Install failed") }
        return json(o)
    }

    static func uninstall(bundleID: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = al_sl_uninstall(pairingPath(), bundleID, nil, nil, &err)
        let e = take(err)
        if rc != 0 { throw SideloadError.message(e ?? "Uninstall failed") }
    }

    static func containerSign(appDir: String) throws -> [String: Any] {
        var out: UnsafeMutablePointer<CChar>?
        var err: UnsafeMutablePointer<CChar>?
        let rc = al_container_sign_as(appDir, Bundle.main.bundleIdentifier ?? "", &out, &err)
        let o = take(out), e = take(err)
        if rc != 0 { throw SideloadError.message(e ?? "Signing failed") }
        return json(o)
    }

    static func containerSignFile(path: String, ident: String) throws {
        var out: UnsafeMutablePointer<CChar>? = nil
        var err: UnsafeMutablePointer<CChar>? = nil
        let rc = al_container_sign_file(path, ident, &out, &err)
        _ = take(out); let e = take(err)
        if rc != 0 { throw SideloadError.message(e ?? "Signing failed") }
    }

    /// Device tools (battery, storage, profiles, crash logs, Media files). BLOCKS.
    static func devTool(_ kind: String, arg: String = "", outPath: String = "") throws -> Any? {
        var out: UnsafeMutablePointer<CChar>? = nil
        var err: UnsafeMutablePointer<CChar>? = nil
        let rc = al_dev_tool(pairingPath(), kind, arg, outPath, &out, &err)
        let o = take(out), e = take(err)
        if rc != 0 { throw SideloadError.message(e ?? "Device tool failed") }
        guard let o, let d = o.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    static func unzip(_ archive: String, to dir: String) -> Bool {
        al_zip_extract_all(archive, dir) == 0
    }
}
