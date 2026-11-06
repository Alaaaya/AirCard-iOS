import XCTest
import Foundation
#if canImport(DiscoveryKit)
@testable import DiscoveryKit
#else
@testable import AirCard_iOS
#endif

// MARK: - zip / macho builders

private func crc32(_ d: Data) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in d { c ^= UInt32(b); for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1 } }
    return ~c
}
private func le16(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255)]) }
private func le32(_ v: UInt32) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }

private func makeZip(_ files: [(String, Data)]) -> Data {
    var out = Data()
    var central = Data()
    for (name, body) in files {
        let off = out.count
        let n = Data(name.utf8)
        let crc = crc32(body)
        let size = UInt32(body.count)
        var lh = Data()
        lh.append(le32(0x04034b50)); lh.append(le16(20)); lh.append(le16(0)); lh.append(le16(0)); lh.append(le16(0)); lh.append(le16(0))
        lh.append(le32(crc)); lh.append(le32(size)); lh.append(le32(size)); lh.append(le16(n.count)); lh.append(le16(0))
        lh.append(n); lh.append(body)
        out.append(lh)
        var ch = Data()
        ch.append(le32(0x02014b50)); ch.append(le16(20)); ch.append(le16(20)); ch.append(le16(0)); ch.append(le16(0)); ch.append(le16(0)); ch.append(le16(0))
        ch.append(le32(crc)); ch.append(le32(size)); ch.append(le32(size)); ch.append(le16(n.count))
        ch.append(le16(0)); ch.append(le16(0)); ch.append(le16(0)); ch.append(le16(0)); ch.append(le32(0)); ch.append(le32(UInt32(off))); ch.append(n)
        central.append(ch)
    }
    let cdOff = out.count
    out.append(central)
    var end = Data()
    end.append(le32(0x06054b50)); end.append(le16(0)); end.append(le16(0)); end.append(le16(files.count)); end.append(le16(files.count))
    end.append(le32(UInt32(central.count))); end.append(le32(UInt32(cdOff))); end.append(le16(0))
    out.append(end)
    return out
}

private func plist(_ d: [String: Any]) -> Data { try! PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0) }

/// Minimal 64-bit little endian Mach-O with optional LC_ENCRYPTION_INFO_64.
private func macho(cpu: UInt32 = 0x0100000C, encrypted: Bool = false, withCmd: Bool = true) -> Data {
    var words: [UInt32] = [0xFEEDFACF, cpu, 0, 2, withCmd ? 1 : 0, withCmd ? 24 : 0, 0, 0]
    if withCmd { words += [0x2C, 24, 0, 0x1000, encrypted ? 1 : 0, 0] }
    var d = Data()
    for w in words { d.append(le32(w)) }
    d.append(Data(repeating: 0, count: 64))
    return d
}

private func ipa(bundle: String = "com.example.app", version: String = "1.2", minOS: String = "15.0", exe: Data? = nil, extra: [(String, Data)] = [], app: String = "Payload/App.app") -> Data {
    let info: [String: Any] = ["CFBundleIdentifier": bundle, "CFBundleShortVersionString": version, "CFBundleVersion": "7",
                               "CFBundleExecutable": "App", "CFBundleName": "App", "MinimumOSVersion": minOS]
    return makeZip([(app + "/Info.plist", plist(info)), (app + "/App", exe ?? macho())] + extra)
}

// MARK: - tests

final class DiscoveryTests: XCTestCase {
    func u(_ s: String) -> URL { URL(string: s)! }

    func testURLPolicyAccepts() {
        XCTAssertNil(DiscoveryURLPolicy.check(u("https://github.com/a/b/releases/download/x/app.ipa")))
        XCTAssertNil(DiscoveryURLPolicy.check(u("https://cdn.example.org:443/a.ipa")))
    }

    func testURLPolicyRejectsMalicious() {
        for s in ["http://example.com/a.ipa", "ftp://example.com/a", "file:///etc/passwd", "https://localhost/a", "https://127.0.0.1/a",
                  "https://2130706433/a", "https://0x7f.0.0.1/a", "https://192.168.1.5/a", "https://10.0.0.1/a", "https://[::1]/a",
                  "https://printer/a", "https://nas.local/a", "https://svc.internal/a", "https://user:pw@example.com/a",
                  "https://example.com:8443/a", "https://169.254.169.254/latest", "https://foo.home.arpa/a",
                  "https://example.com/" + String(repeating: "a", count: 3000)] {
            XCTAssertNotNil(DiscoveryURLPolicy.check(u(s)), s)
        }
    }

    func testQueryParsing() {
        XCTAssertEqual(DiscoveryQuery.parse("https://apps.apple.com/us/app/dramawave/id6670430706"), .appStoreID(id: "6670430706", country: "us"))
        XCTAssertEqual(DiscoveryQuery.parse("DramaWave"), .name("DramaWave"))
        if case .unsupported = DiscoveryQuery.parse("   ") {} else { XCTFail("empty must be unsupported") }
        if case .unsupported = DiscoveryQuery.parse("http://127.0.0.1/x") {} else { XCTFail("unsafe url must be unsupported") }
    }

    private func snap(_ name: String, _ url: String, builtIn: Bool = false, _ apps: [(String, String, String)]) -> DiscoverySourceSnapshot {
        DiscoverySourceSnapshot(name: name, url: url, isBuiltIn: builtIn, apps: apps.map {
            .init(name: $0.0, bundleID: $0.1, developer: "Dev", version: $0.2, iconURL: nil, downloadURL: u("https://example.com/\($0.1)-\($0.2).ipa"))
        })
    }

    func testBundleSearchIsVerified() {
        let s = [snap("S1", "https://s1.example/source.json", [("DramaWave", "com.dramabuzz.app", "2.0")])]
        let r = SourcesDiscovery.search(s, name: nil, bundleID: "com.dramabuzz.app")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.identity, .bundleVerified)
    }

    func testNameSearchIsNameOnlyAndAmbiguityDetected() {
        let s = [snap("S1", "https://s1.example/s.json", [("Spotify", "com.fake.spotify", "1"), ("Spotify Plus", "com.other.spotify", "1")])]
        let r = DiscoveryMatcher.rank(SourcesDiscovery.search(s, name: "spotify", bundleID: nil), query: "spotify")
        XCTAssertGreaterThanOrEqual(r.count, 2)
        XCTAssertTrue(r.allSatisfy { $0.identity == .nameOnly })
        XCTAssertTrue(DiscoveryMatcher.isAmbiguous(r), "two different bundle IDs for one name must be ambiguous")
    }

    func testSameAppAcrossSourcesNotAmbiguous() {
        let s = [snap("A", "https://a.example/s.json", [("Foo", "com.foo.app", "1.0")]), snap("B", "https://b.example/s.json", [("Foo", "com.foo.app", "1.0")])]
        let r = DiscoveryMatcher.rank(SourcesDiscovery.search(s, name: "Foo", bundleID: nil), query: "Foo")
        XCTAssertFalse(DiscoveryMatcher.isAmbiguous(r))
    }

    func testBuiltInSourcesNotTrustedByDefault() {
        var a = DiscoveryAuthorization(authorizedSources: [])
        XCTAssertFalse(a.isAuthorized(sourceURL: "https://s1.example/s.json"))
        a.authorize("https://S1.example/s.json/")
        XCTAssertTrue(a.isAuthorized(sourceURL: "https://s1.example/s.json"))
        a.revoke("https://s1.example/s.json")
        XCTAssertFalse(a.isAuthorized(sourceURL: "https://s1.example/s.json"))
    }

    func testAppleParseDramaWave() {
        let json = """
        {"resultCount":1,"results":[{"trackId":6670430706,"trackName":"DramaWave","bundleId":"com.dramabuzz.app","artistName":"Dev","version":"3.1","minimumOsVersion":"15.0","artworkUrl512":"https://is1.example.com/i.png","trackViewUrl":"https://apps.apple.com/app/id6670430706"}]}
        """
        let l = AppleMetadata.parse(Data(json.utf8))
        XCTAssertEqual(l.first?.bundleID, "com.dramabuzz.app")
        XCTAssertEqual(l.first?.trackID, "6670430706")
        XCTAssertFalse(AppleMetadata.candidate(l[0]).isDownloadable, "metadata is never downloadable")
    }

    func testAppleParseDropsUnsafeIconAndGarbage() {
        let json = #"{"results":[{"trackId":1,"trackName":"X","bundleId":"a.b","artworkUrl512":"http://127.0.0.1/i.png"}]}"#
        XCTAssertNil(AppleMetadata.parse(Data(json.utf8)).first?.iconURL)
        XCTAssertTrue(AppleMetadata.parse(Data("not json".utf8)).isEmpty)
    }

    func testWebBackendRejectsUnsafeDownloads() {
        let json = #"{"results":[{"name":"A","bundleId":"a.b","downloadURL":"http://evil.example/a.ipa"},{"name":"B","bundleId":"b.c","downloadURL":"https://ok.example/b.ipa"}]}"#
        let r = WebBackendProvider.parse(Data(json.utf8))
        XCTAssertEqual(r.map { $0.bundleID }, ["b.c"])
        XCTAssertEqual(r.first?.identity, .nameOnly)
    }

    func testWebBackendPageResultIsReferenceOnly() {
        let json = #"{"results":[{"name":"P","bundleId":"unknown.x.com","pageURL":"https://x.com/page"},{"name":"Bad","bundleId":"a.b","pageURL":"http://x.com/p"}]}"#
        let r = WebBackendProvider.parse(Data(json.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertFalse(r[0].isDownloadable)
        XCTAssertEqual(r[0].identity, .reference)
    }

    // MARK: validator

    private func validate(_ d: Data, bundle: String? = "com.example.app", version: String? = "1.2", os: String? = "18.0") throws -> IPAFacts {
        try IPAValidator.validate(data: d, expectedBundleID: bundle, expectedVersion: version, deviceOS: os)
    }

    func testValidIPA() throws {
        let f = try validate(ipa())
        XCTAssertEqual(f.bundleID, "com.example.app"); XCTAssertEqual(f.version, "1.2")
    }

    func testBundleMismatch() {
        XCTAssertThrowsError(try validate(ipa(bundle: "com.evil.app"))) { XCTAssertEqual($0 as? IPAValidationError, .bundleMismatch(expected: "com.example.app", actual: "com.evil.app")) }
    }

    func testVersionMismatch() {
        XCTAssertThrowsError(try validate(ipa(version: "9.9"))) { XCTAssertEqual($0 as? IPAValidationError, .versionMismatch(expected: "1.2", actual: "9.9")) }
    }

    func testMinOSTooHigh() {
        XCTAssertThrowsError(try validate(ipa(minOS: "99.0"))) { XCTAssertEqual($0 as? IPAValidationError, .minOSTooHigh("99.0")) }
    }

    func testEncryptedRejected() {
        XCTAssertThrowsError(try validate(ipa(exe: macho(encrypted: true)))) { XCTAssertEqual($0 as? IPAValidationError, .encrypted) }
    }

    func testNotArm64Rejected() {
        XCTAssertThrowsError(try validate(ipa(exe: macho(cpu: 0x01000007)))) { XCTAssertEqual($0 as? IPAValidationError, .notArm64) }
    }

    func testUnencryptedArm64WithoutEncryptionCommandPasses() throws {
        _ = try validate(ipa(exe: macho(withCmd: false)))
    }

    func testGarbageAndHtmlRejected() {
        XCTAssertThrowsError(try validate(Data("<html>captcha</html>".utf8)))
        XCTAssertThrowsError(try validate(Data()))
    }

    func testPathTraversalRejected() {
        let d = ipa(extra: [("Payload/App.app/../../evil", Data([1]))])
        XCTAssertThrowsError(try validate(d))
        let d2 = ipa(extra: [("/abs/evil", Data([1]))])
        XCTAssertThrowsError(try validate(d2))
    }

    func testMultipleAppsRejected() {
        let other = plist(["CFBundleIdentifier": "x.y", "CFBundleExecutable": "B"])
        XCTAssertThrowsError(try validate(ipa(extra: [("Payload/Other.app/Info.plist", other), ("Payload/Other.app/B", macho())])))
    }

    func testNoPayloadRejected() {
        XCTAssertThrowsError(try validate(makeZip([("readme.txt", Data("hi".utf8))])))
    }

    func testBadBundleIdentifierWithNilExpectation() {
        XCTAssertThrowsError(try IPAValidator.validate(data: ipa(bundle: "../../x"), expectedBundleID: nil, expectedVersion: nil, deviceOS: nil))
    }

    func testEntryLimitEnforced() {
        var lim = IPALimits(); lim.maxEntries = 1
        XCTAssertThrowsError(try IPAValidator.validate(data: ipa(), expectedBundleID: nil, expectedVersion: nil, deviceOS: nil, limits: lim))
    }

    func testTruncatedZipRejected() {
        let d = ipa(); XCTAssertThrowsError(try validate(d.prefix(d.count / 2)))
    }

    func testProvenanceStripsQuery() {
        XCTAssertEqual(DiscoveryProvenance.strip(u("https://cdn.example.com/a/b.ipa?token=SECRET&exp=1")), "cdn.example.com/a/b.ipa")
    }
}
