import Foundation
import UIKit
import Security
import Darwin

/// First-setup only. USB Trust is the transport identity; a receipt is not Apple authentication.
@MainActor
final class WindowsHandoff {
    static let shared = WindowsHandoff()
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var session: WindowsHandoffCrypto.Session?
    private var timer: Timer?
    private var started = false
    private var closed = false
    private var requestURL: URL { documents.appendingPathComponent("mirsa-handoff-request.json") }
    private var envelopeURL: URL { documents.appendingPathComponent("mirsa-handoff-envelope.json") }
    private var receiptURL: URL { documents.appendingPathComponent("mirsa-handoff-receipt.json") }

    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        check()
        guard !closed else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    private func check() {
        guard !closed, UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable else { return }
        if !started {
            started = true
            Self.recoverInterruptedCredentialWrite()
            // No key survives process death. Discard the previous process's request and response.
            try? removeIfPresent(requestURL)
            try? removeIfPresent(envelopeURL)
            guard Keychain.get("appleid.email") == nil,
                  Keychain.get("appleid.password") == nil else {
                closed = true
                return
            }
            do {
                try removeIfPresent(receiptURL)
                let fresh = WindowsHandoffCrypto.Session()
                try writePublic(JSONEncoder().encode(fresh.request), to: requestURL)
                session = fresh
            } catch { closed = true }
        }
        guard let current = session else { return }
        guard current.isValid(now: Int64(Date().timeIntervalSince1970),
                              uptime: ProcessInfo.processInfo.systemUptime) else {
            finish(current.request.sessionId, status: "rejected")
            return
        }
        guard FileManager.default.fileExists(atPath: envelopeURL.path) else { return }
        do {
            // Never follow links or read an unbounded host-provided file.
            let data = try boundedRegularFile(envelopeURL, limit: 32768)
            let credentials = try current.open(data)
            guard Keychain.get("appleid.email") == nil,
                  Keychain.get("appleid.password") == nil else { throw WindowsHandoffCrypto.Failure.invalid }
            let pairingURL = documents.appendingPathComponent("aircard_pairing.plist")
            let pairingData = try boundedRegularFile(pairingURL, limit: 1048576)
            guard let pairing = try PropertyListSerialization.propertyList(from: pairingData, format: nil) as? [String: Any],
                  pairing["HostID"] is String, pairing["SystemBUID"] is String,
                  pairing["HostPrivateKey"] is Data else { throw WindowsHandoffCrypto.Failure.invalid }
            _ = PairingController.syncCanonicalPairingFile(from: pairingURL.path)
            // Protect pre-existing pairing without changing its technical name.
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                 ofItemAtPath: pairingURL.path)
            try Self.storeCredentials(credentials)
            finish(current.request.sessionId, status: "consumed")
        } catch {
            finish(current.request.sessionId, status: "rejected")
        }
    }

    private func finish(_ id: String, status: String) {
        // Drop RAM private key before publishing a receipt, including on rejection.
        session = nil
        closed = true
        timer?.invalidate()
        timer = nil
        do {
            try removeIfPresent(envelopeURL)
            try removeIfPresent(requestURL)
            let receipt = WindowsHandoffCrypto.Receipt(version: 1, sessionId: id, status: status)
            try writePublic(JSONEncoder().encode(receipt), to: receiptURL)
        } catch {
            // No success receipt if cleanup failed. Never log credentials or decrypted JSON.
            try? removeIfPresent(receiptURL)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func writePublic(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try u.setResourceValues(values)
    }

    private func boundedRegularFile(_ url: URL, limit: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw WindowsHandoffCrypto.Failure.invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= Int64(limit) else { throw WindowsHandoffCrypto.Failure.invalid }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard !data.isEmpty, data.count <= limit else { throw WindowsHandoffCrypto.Failure.invalid }
        return data
    }

    /// Existing Keychain.set intentionally ignores OSStatus; handoff MUST not.
    /// Fresh keys only, verified reads and rollback on partial writes.
    private static func storeCredentials(_ credentials: WindowsHandoffCrypto.Credentials) throws {
        // An interruption between the two existing legacy key names must not strand
        // half an account. The separate journal contains no credential material.
        let journal = journalQuery()
        var marker = journal
        marker[kSecValueData as String] = Data([1])
        marker[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(marker as CFDictionary, nil) == errSecSuccess else {
            throw WindowsHandoffCrypto.Failure.invalid
        }
        var added: [String] = []
        do {
            for (name, value) in [("appleid.email", credentials.email), ("appleid.password", credentials.password)] {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: Keychain.service,
                    kSecAttrAccount as String: name,
                    kSecValueData as String: Data(value.utf8),
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    kSecAttrSynchronizable as String: false
                ]
                guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                    throw WindowsHandoffCrypto.Failure.invalid
                }
                added.append(name)
                guard Keychain.get(name) == value else { throw WindowsHandoffCrypto.Failure.invalid }
            }
            guard SecItemDelete(journal as CFDictionary) == errSecSuccess else {
                throw WindowsHandoffCrypto.Failure.invalid
            }
        } catch {
            for name in added { Keychain.set(name, nil) }
            SecItemDelete(journal as CFDictionary)
            throw error
        }
    }
    private static func journalQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.alaa.mirsa.windows-handoff",
         kSecAttrAccount as String: "credential-write-pending"]
    }

    private static func recoverInterruptedCredentialWrite() {
        var query = journalQuery()
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return }
        Keychain.set("appleid.email", nil)
        Keychain.set("appleid.password", nil)
        SecItemDelete(journalQuery() as CFDictionary)
    }

}
