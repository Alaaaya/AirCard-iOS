import Foundation
import Security
import CryptoKit
import CommonCrypto
import Combine

// Hidden apps (Mirsa-only privacy feature, NOT OS-level security).
// IDs are namespaced: "main:<id>" for the main container, "personal:<UUID>" for personal homes.
// Everything lives in the Keychain (this-device-only). Fail-closed: if state is unreadable or
// corrupted nothing is ever cleared and nothing hidden becomes visible.

enum HiddenNamespace: String { case main, personal }

struct HiddenAppID: Hashable, Codable {
    let raw: String
    init(_ ns: HiddenNamespace, _ id: String) { raw = ns.rawValue + ":" + id }
    init?(raw: String) {
        guard raw.hasPrefix("main:") || raw.hasPrefix("personal:"), raw.split(separator: ":", maxSplits: 1).count == 2 else { return nil }
        self.raw = raw
    }
}

enum HiddenSecretRead { case found(Data), missing, failed }

protocol HiddenSecretStore: AnyObject {
    func read(_ account: String) -> HiddenSecretRead
    @discardableResult func write(_ account: String, _ data: Data) -> Bool
}

final class KeychainHiddenSecretStore: HiddenSecretStore {
    private let service: String
    init(service: String = "com.alaa.mirsa.hiddenapps") { self.service = service }
    private func base(_ a: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: a]
    }
    func read(_ account: String) -> HiddenSecretRead {
        var q = base(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return .missing }
        if s == errSecSuccess, let d = out as? Data { return .found(d) }
        return .failed
    }
    func write(_ account: String, _ data: Data) -> Bool {
        let upd = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if upd == errSecSuccess { return true }
        guard upd == errSecItemNotFound else { return false }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

enum HiddenStoreHealth: Equatable { case ok, faulted }

enum HiddenUnlockResult: Equatable {
    case success
    case wrongPIN(remainingBeforeLock: Int)
    case locked(until: Date)
    case faulted
    case notConfigured
}

enum HiddenPINError: Error, Equatable { case invalidFormat, faulted, alreadySet, storageFailed, wrongPIN, locked(Date) }

private struct HiddenAuthRecord: Codable {
    var v = 1
    var iterations: Int = HiddenAppsStore.kdfIterations
    var salt: Data
    var hash: Data
    var failures: Int = 0
    var lockUntil: Date? = nil
}

private struct HiddenIDsRecord: Codable { var v = 1; var ids: [String] }

@MainActor
final class HiddenAppsStore: ObservableObject {
    static let shared = HiddenAppsStore()
    static let freeAttempts = 5
    static let kdfIterations = 120_000
    static func isValidPIN(_ s: String) -> Bool { (4...6).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber } }

    @Published private(set) var hiddenIDs: Set<String> = []
    @Published private(set) var isUnlocked = false
    @Published private(set) var health: HiddenStoreHealth = .ok
    @Published private(set) var hasPIN = false

    private let secrets: HiddenSecretStore
    private let now: () -> Date
    private var auth: HiddenAuthRecord?
    private var idsFaulted = false

    init(secrets: HiddenSecretStore = KeychainHiddenSecretStore(), now: @escaping () -> Date = Date.init) {
        self.secrets = secrets; self.now = now
        reload()
    }

    // MARK: loading
    func reload() {
        var bad = false
        switch secrets.read("auth") {
        case .missing: auth = nil
        case .failed: bad = true; auth = nil
        case .found(let d):
            if let r = try? JSONDecoder().decode(HiddenAuthRecord.self, from: d), r.v == 1, r.salt.count >= 16, r.hash.count == 32, r.iterations >= 100_000, r.iterations <= 5_000_000 { auth = r } else { bad = true; auth = nil }
        }
        switch secrets.read("ids") {
        case .missing: hiddenIDs = []; idsFaulted = false
        case .failed: idsFaulted = true
        case .found(let d):
            if let r = try? JSONDecoder().decode(HiddenIDsRecord.self, from: d), r.v == 1, r.ids.allSatisfy({ HiddenAppID(raw: $0) != nil }) { hiddenIDs = Set(r.ids); idsFaulted = false } else { idsFaulted = true }
        }
        // hidden ids present but no PIN record (and no read error) is also inconsistent -> fail closed
        if !bad, auth == nil, !hiddenIDs.isEmpty { bad = true }
        hasPIN = auth != nil
        health = (bad || idsFaulted) ? .faulted : .ok
        if health == .faulted { isUnlocked = false }
    }

    // MARK: filtering (central)
    /// Fail-closed: when faulted and ids could not be read, everything not provably visible stays hidden.
    func isHidden(_ id: HiddenAppID) -> Bool { idsFaulted || hiddenIDs.contains(id.raw) }
    func isHidden(_ ns: HiddenNamespace, _ id: String) -> Bool { isHidden(HiddenAppID(ns, id)) }

    /// Presentation filter for home, folders and search. Use unfiltered collections for maintenance and counts.
    func visible<T>(_ items: [T], ns: HiddenNamespace, id: (T) -> String) -> [T] {
        items.filter { !isHidden(ns, id($0)) }
    }
    func hiddenItems<T>(_ items: [T], ns: HiddenNamespace, id: (T) -> String) -> [T] {
        guard isUnlocked, health == .ok else { return [] }
        return items.filter { hiddenIDs.contains(HiddenAppID(ns, id($0)).raw) }
    }

    // MARK: PIN
    func setPIN(_ pin: String) throws {
        guard health == .ok else { throw HiddenPINError.faulted }
        guard auth == nil else { throw HiddenPINError.alreadySet }
        guard Self.isValidPIN(pin) else { throw HiddenPINError.invalidFormat }
        var salt = Data(count: 16)
        let ok = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) } == errSecSuccess
        guard ok else { throw HiddenPINError.storageFailed }
        let rec = HiddenAuthRecord(salt: salt, hash: Self.hash(pin, salt, iterations: Self.kdfIterations))
        guard persist(rec) else { throw HiddenPINError.storageFailed }
        auth = rec; hasPIN = true; isUnlocked = true
    }

    func unlock(_ pin: String) -> HiddenUnlockResult {
        reload()
        guard health == .ok else { return .faulted }
        guard var rec = auth else { return .notConfigured }
        if let until = rec.lockUntil, until > now() { return .locked(until: until) }
        guard Self.isValidPIN(pin) else { return fail(&rec) }
        if Self.constantTimeEqual(Self.hash(pin, rec.salt, iterations: rec.iterations), rec.hash) {
            rec.failures = 0; rec.lockUntil = nil
            guard persist(rec) else { return .faulted }
            auth = rec; isUnlocked = true
            return .success
        }
        return fail(&rec)
    }

    private func fail(_ rec: inout HiddenAuthRecord) -> HiddenUnlockResult {
        rec.failures += 1
        var result = HiddenUnlockResult.wrongPIN(remainingBeforeLock: max(0, Self.freeAttempts - rec.failures))
        if rec.failures >= Self.freeAttempts {
            // 30s, 1m, 2m, 4m ... capped at 1h
            let step = rec.failures - Self.freeAttempts
            let secs = min(3600.0, 30.0 * pow(2.0, Double(min(step, 12))))
            let until = now().addingTimeInterval(secs)
            rec.lockUntil = until
            result = .locked(until: until)
        }
        // persist BEFORE answering so killing the app cannot reset the counter
        if persist(rec) { auth = rec } else { return .faulted }
        return result
    }

    func changePIN(old: String, new: String) throws {
        guard Self.isValidPIN(new) else { throw HiddenPINError.invalidFormat }
        switch unlock(old) {
        case .success: break
        case .locked(let d): throw HiddenPINError.locked(d)
        case .faulted: throw HiddenPINError.faulted
        default: throw HiddenPINError.wrongPIN
        }
        guard var rec = auth else { throw HiddenPINError.faulted }
        var salt = Data(count: 16)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else { throw HiddenPINError.storageFailed }
        rec.salt = salt; rec.iterations = Self.kdfIterations; rec.hash = Self.hash(new, salt, iterations: Self.kdfIterations); rec.failures = 0; rec.lockUntil = nil
        guard persist(rec) else { throw HiddenPINError.storageFailed }
        auth = rec
    }

    /// Call on background / dismiss.
    func lock() { isUnlocked = false }

    // MARK: hide / unhide (hide needs a PIN to exist; unhide needs unlock)
    @discardableResult
    func hide(_ id: HiddenAppID) -> Bool {
        guard health == .ok, hasPIN else { return false }
        if hiddenIDs.contains(id.raw) { return true }
        var n = hiddenIDs; n.insert(id.raw)
        guard persistIDs(n) else { return false }
        hiddenIDs = n; return true
    }
    @discardableResult
    func unhide(_ id: HiddenAppID) -> Bool {
        guard health == .ok, isUnlocked else { return false }
        var n = hiddenIDs; n.remove(id.raw)
        guard persistIDs(n) else { return false }
        hiddenIDs = n; return true
    }
    /// Drop ids of apps that no longer exist. Only call with a COMPLETE list for the namespace.
    func prune(_ ns: HiddenNamespace, existing: Set<String>) {
        guard health == .ok else { return }
        let prefix = ns.rawValue + ":"
        let n = hiddenIDs.filter { !$0.hasPrefix(prefix) || existing.contains(String($0.dropFirst(prefix.count))) }
        if n != hiddenIDs, persistIDs(n) { hiddenIDs = n }
    }

    // MARK: internals
    private func persist(_ rec: HiddenAuthRecord) -> Bool {
        guard let d = try? JSONEncoder().encode(rec) else { return false }
        return secrets.write("auth", d)
    }
    private func persistIDs(_ ids: Set<String>) -> Bool {
        guard let d = try? JSONEncoder().encode(HiddenIDsRecord(ids: ids.sorted())) else { return false }
        return secrets.write("ids", d)
    }
    /// PBKDF2-HMAC-SHA256 via CommonCrypto (standard KDF, 32-byte output).
    static func hash(_ pin: String, _ salt: Data, iterations: Int) -> Data {
        let pw = Array(pin.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { sp in
            pw.withUnsafeBufferPointer { pp in
                pp.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pw.count) { pc in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pc, pw.count,
                        sp.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, 32)
                }
            }
        }
        return status == Int32(kCCSuccess) ? Data(out) : Data()
    }
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
