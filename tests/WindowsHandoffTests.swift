import XCTest
import CryptoKit
#if canImport(WindowsHandoffKit)
@testable import WindowsHandoffKit
#else
@testable import AirCard_iOS
#endif

final class WindowsHandoffTests: XCTestCase {
    private let now: Int64 = 1_800_000_000
    private let uptime: TimeInterval = 1000

    private func makeEnvelope(_ session: WindowsHandoffCrypto.Session, email: String = "person@example.test",
                              password: String = "secret-test-only", payloadSession: String? = nil,
                              payloadExpiry: Int64? = nil, payloadVersion: Int = 1,
                              envelopeSession: String? = nil, envelopeVersion: Int = 1,
                              aadOverride: String? = nil) throws -> Data {
        let r = session.request
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: r.publicKey)))
        let shared = try sender.sharedSecretFromKeyAgreement(with: peer)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(r.sessionId.utf8),
            sharedInfo: Data("Mirsa Windows Handoff v1".utf8), outputByteCount: 32)
        let payload = WindowsHandoffCrypto.Credentials(version: payloadVersion,
            sessionId: payloadSession ?? r.sessionId, expiresAt: payloadExpiry ?? r.expiresAt,
            email: email, password: password)
        let aad = Data((aadOverride ?? "mirsa-handoff-v1|\(r.sessionId)|\(r.expiresAt)").utf8)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(payload), using: key, authenticating: aad)
        return try JSONEncoder().encode(WindowsHandoffCrypto.Envelope(version: envelopeVersion,
            sessionId: envelopeSession ?? r.sessionId,
            publicKey: sender.publicKey.rawRepresentation.base64EncodedString(),
            sealed: XCTUnwrap(sealed.combined).base64EncodedString()))
    }

    func testRoundTripAndRequestShape() throws {
        let s = WindowsHandoffCrypto.Session(now: now, uptime: uptime)
        XCTAssertEqual(s.request.version, 1)
        XCTAssertEqual(s.request.expiresAt - s.request.createdAt, 600)
        XCTAssertEqual(Data(base64Encoded: s.request.publicKey)?.count, 32)
        XCTAssertEqual(s.request.sessionId, s.request.sessionId.lowercased())
        let result = try s.open(makeEnvelope(s), now: now + 1, uptime: uptime + 1)
        XCTAssertEqual(result.email, "person@example.test")
        XCTAssertEqual(result.password, "secret-test-only")
    }
    func testSessionAndKeysAreFresh() {
        let a = WindowsHandoffCrypto.Session()
        let b = WindowsHandoffCrypto.Session()
        XCTAssertNotEqual(a.request.sessionId, b.request.sessionId)
        XCTAssertNotEqual(a.request.publicKey, b.request.publicKey)
    }
    func testExpiryAndClockRollback() throws {
        let s = WindowsHandoffCrypto.Session(now: now, uptime: uptime)
        let data = try makeEnvelope(s)
        for (wall, mono) in [(now + 600, uptime + 1), (now - 1, uptime + 1),
                             (now + 1, uptime + 600), (now + 1, uptime - 1)] {
            XCTAssertThrowsError(try s.open(data, now: wall, uptime: mono))
        }
    }
    func testEnvelopeVersionAndSessionBinding() throws {
        let s = WindowsHandoffCrypto.Session(now: now, uptime: uptime)
        XCTAssertThrowsError(try s.open(makeEnvelope(s, envelopeSession: "wrong"), now: now, uptime: uptime))
        XCTAssertThrowsError(try s.open(makeEnvelope(s, envelopeVersion: 2), now: now, uptime: uptime))
    }
    func testPayloadVersionSessionAndExpiryBinding() throws {
        let s = WindowsHandoffCrypto.Session(now: now, uptime: uptime)
        XCTAssertThrowsError(try s.open(makeEnvelope(s, payloadSession: "wrong"), now: now, uptime: uptime))
        XCTAssertThrowsError(try s.open(makeEnvelope(s, payloadExpiry: now + 599), now: now, uptime: uptime))
        XCTAssertThrowsError(try s.open(makeEnvelope(s, payloadVersion: 2), now: now, uptime: uptime))
    }
    func testAuthenticationTagAndAAD() throws {
        let s = WindowsHandoffCrypto.Session(now: now, uptime: uptime)
        XCTAssertThrowsError(try s.open(makeEnvelope(s, aadOverride: "wrong"), now: now, uptime: uptime))
        let envelope = try JSONDecoder().decode(WindowsHandoffCrypto.Envelope.self, from: makeEnvelope(s))
        var sealed = try XCTUnwrap(Data(base64Encoded: envelope.sealed))
        sealed[sealed.count - 1] ^= 1
        let changed = WindowsHandoffCrypto.Envelope(version: 1, sessionId: s.request.sessionId,
            publicKey: envelope.publicKey, sealed: sealed.base64EncodedString())
        XCTAssertThrowsError(try s.open(JSONEncoder().encode(changed), now: now, uptime: uptime))
    }
    func testOldEnvelopeCannotReplayIntoNewSession() throws {
        let a = WindowsHandoffCrypto.Session(now: now, uptime: uptime)
        let b = WindowsHandoffCrypto.Session(now: now, uptime: uptime)
        XCTAssertThrowsError(try b.open(makeEnvelope(a), now: now, uptime: uptime))
    }
    func testCredentialBounds() throws {
        let s = WindowsHandoffCrypto.Session(now: now, uptime: uptime)
        for email in ["", "   ", String(repeating: "a", count: 321)] {
            XCTAssertThrowsError(try s.open(makeEnvelope(s, email: email), now: now, uptime: uptime))
        }
        for password in ["", String(repeating: "a", count: 4097)] {
            XCTAssertThrowsError(try s.open(makeEnvelope(s, password: password), now: now, uptime: uptime))
        }
        XCTAssertNoThrow(try s.open(makeEnvelope(s, password: String(repeating: "a", count: 4096)), now: now, uptime: uptime))
    }
    func testMalformedOversizedAndLowOrderKeys() throws {
        let s = WindowsHandoffCrypto.Session(now: now, uptime: uptime)
        for data in [Data(), Data("not json".utf8), Data(repeating: 65, count: 32769)] {
            XCTAssertThrowsError(try s.open(data, now: now, uptime: uptime))
        }
        for key in ["invalid", Data(repeating: 0, count: 31).base64EncodedString(),
                    Data(repeating: 0, count: 32).base64EncodedString()] {
            let e = WindowsHandoffCrypto.Envelope(version: 1, sessionId: s.request.sessionId,
                publicKey: key, sealed: Data(repeating: 0, count: 28).base64EncodedString())
            XCTAssertThrowsError(try s.open(JSONEncoder().encode(e), now: now, uptime: uptime))
        }
    }
}
