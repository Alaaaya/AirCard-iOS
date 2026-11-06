import Foundation
import Security

// Anonymous Supabase Auth client for the optional web search backend.
// Only the project URL and the PUBLIC publishable/anon key are configured. No provider key, service key or shared token exists in the app.
// The session (access + refresh token) lives in the Keychain, this-device-only.

struct DiscoverySession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

protocol DiscoverySessionStore: AnyObject {
    func load() -> DiscoverySession?
    func save(_ s: DiscoverySession?)
}

protocol DiscoveryAuthHTTP {
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (Data, Int)
}

protocol DiscoveryTokenProvider {
    func token(forceRefresh: Bool) async throws -> String
}

enum DiscoveryAuthError: Error, Equatable, LocalizedError {
    case notConfigured
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Web search is not configured."
        case .failed(let m): return m
        }
    }
}

final class KeychainSessionStore: DiscoverySessionStore {
    private let service = "com.alaa.mirsa.discovery.session"
    private var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] }
    func load() -> DiscoverySession? {
        var q = base; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(DiscoverySession.self, from: d)
    }
    func save(_ s: DiscoverySession?) {
        SecItemDelete(base as CFDictionary)
        guard let s, let d = try? JSONEncoder().encode(s) else { return }
        var add = base
        add[kSecValueData as String] = d
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    /// Removes the old shared-token item from earlier builds.
    static func removeLegacyToken() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.alaa.mirsa.discovery"] as CFDictionary)
    }
}

enum DiscoveryAuthParse {
    /// Parses a Supabase auth session response.
    static func session(_ data: Data, now: Date) -> DiscoverySession? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let a = o["access_token"] as? String, !a.isEmpty,
              let r = o["refresh_token"] as? String, !r.isEmpty else { return nil }
        let life = (o["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return DiscoverySession(accessToken: a, refreshToken: r, expiresAt: now.addingTimeInterval(max(0, min(life, 86_400))))
    }
}

/// Bounded flow per call: use the stored token while it is valid; otherwise refresh ONCE;
/// if the refresh token is rejected, do ONE anonymous sign-up. No loops.
actor DiscoveryAuthClient: DiscoveryTokenProvider {
    static let skew: TimeInterval = 60
    private let projectURL: URL
    private let key: String
    private let store: DiscoverySessionStore
    private let http: DiscoveryAuthHTTP
    private let now: () -> Date

    init(projectURL: URL, publishableKey: String, store: DiscoverySessionStore, http: DiscoveryAuthHTTP, now: @escaping () -> Date = Date.init) {
        self.projectURL = projectURL; self.key = publishableKey; self.store = store; self.http = http; self.now = now
    }

    func token(forceRefresh: Bool) async throws -> String {
        let current = store.load()
        if !forceRefresh, let s = current, s.expiresAt.timeIntervalSince(now()) > Self.skew { return s.accessToken }
        if let s = current {
            let (code, data) = try await call("auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                              body: ["refresh_token": s.refreshToken])
            if (200..<300).contains(code), let n = DiscoveryAuthParse.session(data, now: now()) { store.save(n); return n.accessToken }
            if !(400..<500).contains(code) { throw DiscoveryAuthError.failed("Sign-in service answered \(code).") }
            store.save(nil) // refresh token rejected: start over with one sign-up
        }
        let (code, data) = try await call("auth/v1/signup", query: [], body: [:])
        guard (200..<300).contains(code), let n = DiscoveryAuthParse.session(data, now: now()) else {
            throw DiscoveryAuthError.failed(code == 422 || code == 400 || code == 403 ? "Anonymous sign-in is not enabled on that project." : "Sign-in service answered \(code).")
        }
        store.save(n)
        return n.accessToken
    }

    private func call(_ path: String, query: [URLQueryItem], body: [String: String]) async throws -> (Int, Data) {
        var c = URLComponents(url: projectURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { c?.queryItems = query }
        guard let url = c?.url else { throw DiscoveryAuthError.notConfigured }
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let (data, code) = try await http.post(url, headers: ["apikey": key, "content-type": "application/json"], body: payload)
        return (code, data)
    }
}

extension WebBackendConfig {
    /// A service-role or secret key must never be configured in the app.
    static func looksSecret(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.hasPrefix("sb_secret_") { return true }
        let parts = k.split(separator: ".")
        guard parts.count == 3 else { return false }
        var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
        return (o["role"] as? String) == "service_role"
    }
}
