import XCTest
#if canImport(DiscoveryKit)
@testable import DiscoveryKit
#else
@testable import AirCard_iOS
#endif

private final class MemSecrets: HiddenSecretStore {
    var d: [String: Data] = [:]; var failRead = false; var failWrite = false
    func read(_ a: String) -> HiddenSecretRead { failRead ? .failed : (d[a].map { .found($0) } ?? .missing) }
    func write(_ a: String, _ x: Data) -> Bool { if failWrite { return false }; d[a] = x; return true }
}

@MainActor
final class HiddenAppsTests: XCTestCase {
    var t = Date(timeIntervalSince1970: 1_000_000)
    func make(_ m: MemSecrets = MemSecrets()) -> (HiddenAppsStore, MemSecrets) { (HiddenAppsStore(secrets: m, now: { self.t }), m) }

    func testPINValidation() {
        XCTAssertFalse(HiddenAppsStore.isValidPIN("123")); XCTAssertFalse(HiddenAppsStore.isValidPIN("1234567"))
        XCTAssertFalse(HiddenAppsStore.isValidPIN("12a4")); XCTAssertTrue(HiddenAppsStore.isValidPIN("1234")); XCTAssertTrue(HiddenAppsStore.isValidPIN("123456"))
    }
    func testHideNeedsPINAndFiltersNamespaced() throws {
        let (s, _) = make(); let a = HiddenAppID(.main, "x"), b = HiddenAppID(.personal, "x")
        XCTAssertFalse(s.hide(a)); try s.setPIN("4321")
        XCTAssertTrue(s.hide(a)); XCTAssertTrue(s.hide(a)); XCTAssertEqual(s.hiddenIDs.count, 1)
        XCTAssertTrue(s.isHidden(a)); XCTAssertFalse(s.isHidden(b))
        XCTAssertEqual(s.visible(["x", "y"], ns: .main, id: { $0 }), ["y"])
        XCTAssertEqual(s.visible(["x", "y"], ns: .personal, id: { $0 }), ["x", "y"])
    }
    func testHashedNotPlainAndPersists() throws {
        let (s, m) = make(); try s.setPIN("4321"); s.hide(HiddenAppID(.main, "a"))
        XCTAssertFalse(String(decoding: m.d["auth"]!, as: UTF8.self).contains("4321"))
        let s2 = HiddenAppsStore(secrets: m, now: { self.t })
        XCTAssertFalse(s2.isUnlocked); XCTAssertTrue(s2.isHidden(.main, "a")); XCTAssertEqual(s2.unlock("4321"), .success)
    }
    func testWrongPINRateLimitPersistsAcrossRelaunch() throws {
        let (s, m) = make(); try s.setPIN("1111"); s.lock()
        for _ in 0..<4 { if case .wrongPIN = s.unlock("2222") {} else { XCTFail() } }
        guard case .locked = s.unlock("2222") else { return XCTFail() }
        let s2 = HiddenAppsStore(secrets: m, now: { self.t })
        guard case .locked = s2.unlock("1111") else { return XCTFail("correct PIN must be refused while locked") }
        t = t.addingTimeInterval(31); XCTAssertEqual(s2.unlock("1111"), .success)
    }
    func testUnhideRequiresUnlock() throws {
        let (s, _) = make(); let a = HiddenAppID(.personal, "u"); try s.setPIN("1234"); s.hide(a); s.lock()
        XCTAssertFalse(s.unhide(a)); XCTAssertTrue(s.isHidden(a))
        XCTAssertEqual(s.unlock("1234"), .success); XCTAssertTrue(s.unhide(a)); XCTAssertFalse(s.isHidden(a))
    }
    func testLockedHidesItemsList() throws {
        let (s, _) = make(); try s.setPIN("1234"); s.hide(HiddenAppID(.main, "a"))
        XCTAssertEqual(s.hiddenItems(["a", "b"], ns: .main, id: { $0 }), ["a"]); s.lock()
        XCTAssertTrue(s.hiddenItems(["a", "b"], ns: .main, id: { $0 }).isEmpty)
    }
    func testCorruptedFailsClosedWithoutClearing() throws {
        let (s, m) = make(); try s.setPIN("1234"); s.hide(HiddenAppID(.main, "a"))
        m.d["ids"] = Data("garbage".utf8); s.reload()
        XCTAssertEqual(s.health, .faulted); XCTAssertTrue(s.isHidden(.main, "anything")); XCTAssertEqual(s.unlock("1234"), .faulted)
        XCTAssertEqual(m.d["ids"], Data("garbage".utf8)); XCTAssertFalse(s.hide(HiddenAppID(.main, "b")))
    }
    func testKeychainReadFailureFailsClosed() throws {
        let (s, m) = make(); try s.setPIN("1234"); s.hide(HiddenAppID(.main, "a"))
        m.failRead = true; s.reload()
        XCTAssertEqual(s.health, .faulted); XCTAssertTrue(s.isHidden(.personal, "z")); XCTAssertFalse(s.isUnlocked)
    }
    func testIDsWithoutAuthIsFaulted() throws {
        let (s, m) = make(); try s.setPIN("1234"); s.hide(HiddenAppID(.main, "a")); m.d["auth"] = nil
        s.reload(); XCTAssertEqual(s.health, .faulted)
    }
    func testWriteFailureDoesNotChangeState() throws {
        let (s, m) = make(); try s.setPIN("1234"); m.failWrite = true
        XCTAssertFalse(s.hide(HiddenAppID(.main, "a"))); XCTAssertFalse(s.isHidden(.main, "a"))
    }
    func testChangePINAndPrune() throws {
        let (s, _) = make(); try s.setPIN("1234"); s.hide(HiddenAppID(.main, "a")); s.hide(HiddenAppID(.personal, "p"))
        XCTAssertThrowsError(try s.changePIN(old: "0000", new: "5678"))
        try s.changePIN(old: "1234", new: "5678"); s.lock(); XCTAssertEqual(s.unlock("5678"), .success)
        s.prune(.main, existing: []); XCTAssertEqual(s.hiddenIDs, ["personal:p"])
    }
    func testKDFKnownVectorAndSeparation() {
        // RFC 7914-style PBKDF2-HMAC-SHA256 vector: P="password" S="salt" c=1 dkLen=32
        let v = HiddenAppsStore.hash("password", Data("salt".utf8), iterations: 1)
        XCTAssertEqual(v.map { String(format: "%02x", $0) }.joined(), "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        let salt = Data(repeating: 1, count: 16), salt2 = Data(repeating: 2, count: 16)
        let a = HiddenAppsStore.hash("1234", salt, iterations: 1000)
        XCTAssertNotEqual(a, HiddenAppsStore.hash("1235", salt, iterations: 1000))
        XCTAssertNotEqual(a, HiddenAppsStore.hash("1234", salt2, iterations: 1000))
        XCTAssertNotEqual(a, HiddenAppsStore.hash("1234", salt, iterations: 1001))
        XCTAssertEqual(a.count, 32)
    }
    func testTamperedSchemaFailsClosed() throws {
        let (s, m) = make(); try s.setPIN("1234"); s.hide(HiddenAppID(.main, "a"))
        m.d["ids"] = Data(#"{"v":2,"ids":["main:a"]}"#.utf8); s.reload(); XCTAssertEqual(s.health, .faulted)
        m.d["ids"] = Data(#"{"v":1,"ids":["main:a","junk"]}"#.utf8); s.reload(); XCTAssertEqual(s.health, .faulted)
        m.d["ids"] = Data(#"{"v":1,"ids":["main:a"]}"#.utf8); s.reload(); XCTAssertEqual(s.health, .ok)
    }
    func testBadAuthWithValidIDsFaultsButKeepsKnownHidden() throws {
        let (s, m) = make(); try s.setPIN("1234")
        s.hide(HiddenAppID(.main, "a")); s.hide(HiddenAppID(.personal, "p"))
        let idsBefore = m.d["ids"]
        for bad in [Data("garbage".utf8), Data(#"{"v":2,"iterations":120000,"salt":"AAAAAAAAAAAAAAAAAAAAAA==","hash":"AA=="}"#.utf8)] {
            m.d["auth"] = bad; s.reload()
            XCTAssertEqual(s.health, .faulted)
            XCTAssertEqual(s.unlock("1234"), .faulted); XCTAssertFalse(s.isUnlocked)
            XCTAssertTrue(s.isHidden(.main, "a")); XCTAssertTrue(s.isHidden(.personal, "p"))
            XCTAssertFalse(s.isHidden(.main, "other")); XCTAssertFalse(s.isHidden(.personal, "p2"))
            XCTAssertEqual(s.visible(["a", "b"], ns: .main, id: { $0 }), ["b"])
            XCTAssertTrue(s.hiddenItems(["a"], ns: .main, id: { $0 }).isEmpty)
            XCTAssertFalse(s.unhide(HiddenAppID(.main, "a"))); XCTAssertFalse(s.hide(HiddenAppID(.main, "b")))
            XCTAssertEqual(m.d["ids"], idsBefore); XCTAssertEqual(s.hiddenIDs, ["main:a", "personal:p"])
            XCTAssertEqual(m.d["auth"], bad)
        }
    }
    func testSetPINWriteFailureLeavesNoPIN() {
        let (s, m) = make(); m.failWrite = true
        XCTAssertThrowsError(try s.setPIN("1234")) { XCTAssertEqual($0 as? HiddenPINError, .storageFailed) }
        XCTAssertFalse(s.hasPIN); XCTAssertFalse(s.isUnlocked); XCTAssertNil(m.d["auth"])
    }
    func testUnlockWriteFailureDoesNotUnlock() throws {
        let (s, m) = make(); try s.setPIN("1234"); s.lock(); m.failWrite = true
        XCTAssertEqual(s.unlock("1234"), .faulted); XCTAssertFalse(s.isUnlocked)
        if case .wrongPIN = s.unlock("0000") { XCTFail("failure counter must not silently succeed") }
    }
    func testIDParsing() { XCTAssertNil(HiddenAppID(raw: "bogus")); XCTAssertNil(HiddenAppID(raw: "main:")); XCTAssertNotNil(HiddenAppID(raw: "personal:ABC")) }
}
