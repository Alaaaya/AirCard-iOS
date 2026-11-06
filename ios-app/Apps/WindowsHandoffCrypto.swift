import Foundation
import CryptoKit

/// Versioned, bounded USB handoff. Private keys never leave RAM.
enum WindowsHandoffCrypto {
    struct Request: Codable, Equatable {
        let version: Int
        let sessionId: String
        let publicKey: String
        let createdAt: Int64
        let expiresAt: Int64
    }
    struct Envelope: Codable {
        let version: Int
        let sessionId: String
        let publicKey: String
        let sealed: String
    }
    struct Credentials: Codable, Equatable {
        let version: Int
        let sessionId: String
        let expiresAt: Int64
        let email: String
        let password: String
    }
    struct Receipt: Codable {
        let version: Int
        let sessionId: String
        let status: String
    }
    enum Failure: Error { case invalid }

    struct Session {
        let request: Request
        fileprivate let privateKey: Curve25519.KeyAgreement.PrivateKey
        private let startedUptime: TimeInterval

        init(now: Int64 = Int64(Date().timeIntervalSince1970),
             uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            let key = Curve25519.KeyAgreement.PrivateKey()
            privateKey = key
            startedUptime = uptime
            request = Request(version: 1, sessionId: UUID().uuidString.lowercased(),
                              publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
                              createdAt: now, expiresAt: now + 600)
        }

        func isValid(now: Int64, uptime: TimeInterval) -> Bool {
            now >= request.createdAt && now < request.expiresAt &&
                uptime >= startedUptime && uptime - startedUptime < 600
        }

        func open(_ data: Data, now: Int64 = Int64(Date().timeIntervalSince1970),
                  uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Credentials {
            guard data.count <= 32768, isValid(now: now, uptime: uptime) else { throw Failure.invalid }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.sessionId == request.sessionId,
                  let sender = Data(base64Encoded: envelope.publicKey), sender.count == 32,
                  let sealed = Data(base64Encoded: envelope.sealed),
                  sealed.count >= 28, sealed.count <= 16412 else { throw Failure.invalid }
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sender)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            let key = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: Data(request.sessionId.utf8),
                sharedInfo: Data("Mirsa Windows Handoff v1".utf8), outputByteCount: 32)
            let aad = Data("mirsa-handoff-v1|\(request.sessionId)|\(request.expiresAt)".utf8)
            var plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed),
                                            using: key, authenticating: aad)
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            guard plaintext.count <= 16384 else { throw Failure.invalid }
            let credentials = try JSONDecoder().decode(Credentials.self, from: plaintext)
            guard credentials.version == 1, credentials.sessionId == request.sessionId,
                  credentials.expiresAt == request.expiresAt,
                  !credentials.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  credentials.email.utf8.count <= 320, !credentials.password.isEmpty,
                  credentials.password.utf8.count <= 4096 else { throw Failure.invalid }
            return credentials
        }
    }
}
