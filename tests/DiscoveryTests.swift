import XCTest
import Foundation
#if canImport(DiscoveryKit)
@testable import DiscoveryKit
#else
@testable import Mirsa
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

    func testSourceMetadataIsNotArchiveVerified() {
        let s = [snap("S1", "https://s1.example/source.json", [("DramaWave", "com.dramabuzz.app", "2.0")])]
        let r = SourcesDiscovery.search(s, name: nil, bundleID: "com.dramabuzz.app")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.identity, .nameOnly)
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
        let json = #"{"results":[{"name":"P","bundleId":"unknown.x.com","pageURL":"https://downloads.example.com/page"},{"name":"Bad","bundleId":"a.b","pageURL":"http://downloads.example.com/p"}]}"#
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
    func testWebMetadataNeverVerifiesBundleAndFiltersAndroid() {
        let data = Data(#"{"results":[{"name":"App","bundleId":"com.requested.app","pageURL":"https://example.com/p"},{"name":"App APK for Android","bundleId":"","pageURL":"https://apkpure.com/a"},{"name":"App iOS","bundleId":"","pageURL":"https://example.com/app","downloadURL":"https://example.com/app.ipa"}]}"#.utf8)
        let r = WebBackendProvider.parse(data)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].identity, .reference)
        XCTAssertEqual(r[1].identity, .nameOnly)
        XCTAssertTrue(r[1].isDownloadable)
        XCTAssertEqual(r[1].bundleID, "")
    }

    func testCanonicalAppleURLParsing() {
        for (url, cc) in [
            ("https://apps.apple.com/de/app/dramawave/id6670430706?l=ar", "de"),
            ("https://apps.apple.com/sa/app/دراما/id6670430706", "sa"),
            ("https://itunes.apple.com/us/app/id6670430706", "us")
        ] { XCTAssertEqual(DiscoveryQuery.parse(url), .appStoreID(id: "6670430706", country: cc)) }
        for url in [
            "http://apps.apple.com/us/app/id6670430706", "https://apps.apple.com.evil.com/us/app/id6670430706",
            "https://apps.apple.com@evil.com/us/app/id6670430706", "https://user:pw@apps.apple.com/us/app/id6670430706",
            "https://apps.apple.com/us/app/notid6670430706", "https://apps.apple.com/us/app/id6670430706junk",
            "https://apps.apple.com/us/app/id6670430706/extra", "https://apps.apple.com/search?id=id6670430706",
            "https://apps.apple.com/us/app/id6670430706id123456", "https://apps.apple.com:8443/us/app/id6670430706"
        ] {
            if case .unsupported = DiscoveryQuery.parse(url) {} else { XCTFail(url) }
        }
    }

    func testNoSubstringOrJoinedTokenMatches() {
        XCTAssertEqual(DiscoveryMatcher.score(query: "DramaWave", name: "DramaWaves hashtags"), 0)
        XCTAssertEqual(DiscoveryMatcher.score(query: "Drama Wave", name: "DramaWave"), 0)
        XCTAssertEqual(DiscoveryMatcher.score(query: "DramaWave", name: "Billboard 1922"), 0)
        XCTAssertGreaterThan(DiscoveryMatcher.score(query: "DramaWave", name: "DramaWave official IPA"), 0)
        XCTAssertGreaterThan(DiscoveryMatcher.score(query: "Café", name: "CAFE IPA"), 0)
    }

    func testBlockedWebReferencesAndDownloadsNeverBecomeCards() {
        for host in ["x.com", "instagram.com", "commons.wikimedia.org", "decrypt.day", "cdn.decrypt.day"] {
            let data = try! JSONSerialization.data(withJSONObject: ["results": [
                ["name": "DramaWave", "pageURL": "https://" + host + "/app",
                 "downloadURL": "https://" + host + "/fake.ipa"]]])
            XCTAssertTrue(WebBackendProvider.parse(data).isEmpty, host)
        }
    }

    private struct MetadataHTTP: DiscoveryHTTP {
        let body: Data
        func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) { (body, 200) }
    }
    private struct RejectVerifier: DiscoveryIPAVerifying {
        func verify(_ c: DiscoveryCandidate, expectedBundleID: String?, queryName: String) async -> DiscoveryCandidate? { nil }
    }
    private var appleFixture: Data {
        Data(#"{"results":[{"trackId":6670430706,"trackName":"DramaWave","bundleId":"com.dramabuzz.app","artistName":"Publisher","version":"1.2"}]}"#.utf8)
    }
    func testMetadataOnlyOutcomeHasNoCardsAndExactArabicEmpty() async {
        let o = await DiscoveryEngine.run(input: "https://apps.apple.com/us/app/id6670430706", sources: [],
            web: .init(projectURL: nil, publishableKey: nil), http: MetadataHTTP(body: appleFixture),
            verifier: RejectVerifier())
        XCTAssertTrue(o.candidates.isEmpty)
        XCTAssertEqual(o.note, "ما لقيت IPA لهالتطبيق")
    }

    private struct BytesVerifier: DiscoveryIPAVerifying {
        let bytes: Data
        func verify(_ c: DiscoveryCandidate, expectedBundleID: String?, queryName: String) async -> DiscoveryCandidate? {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try bytes.write(to: file)
                return try DiscoveryIPAVerifier.validated(c, file: file, expectedBundleID: expectedBundleID, queryName: queryName)
            } catch { return nil }
        }
    }
    func testFakeIPANeverDisplayedAndRealIPAUsesActualIdentity() async {
        let sources = [snap("My source", "https://source.example.com/source.json",
            [("DramaWave", "com.dramabuzz.app", "1.2")])]
        let web = WebBackendConfig(projectURL: nil, publishableKey: nil)
        for fake in [Data("<html>Login required</html>".utf8), makeZip([("readme.txt", Data([1]))])] {
            let o = await DiscoveryEngine.run(input: "https://apps.apple.com/us/app/id6670430706", sources: sources,
                web: web, http: MetadataHTTP(body: appleFixture), verifier: BytesVerifier(bytes: fake))
            XCTAssertTrue(o.candidates.isEmpty)
            XCTAssertEqual(o.note, "ما لقيت IPA لهالتطبيق")
        }
        let real = await DiscoveryEngine.run(input: "https://apps.apple.com/us/app/id6670430706", sources: sources,
            web: web, http: MetadataHTTP(body: appleFixture),
            verifier: BytesVerifier(bytes: ipa(bundle: "com.dramabuzz.app")))
        XCTAssertEqual(real.candidates.count, 1)
        XCTAssertEqual(real.candidates.first?.bundleID, "com.dramabuzz.app")
        XCTAssertEqual(real.candidates.first?.version, "1.2")
        XCTAssertEqual(real.candidates.first?.sourceName, "My source")
        XCTAssertEqual(real.candidates.first?.identity, .bundleVerified)
        XCTAssertTrue(real.candidates.allSatisfy { $0.isDownloadable && $0.origin != .appleMetadata && $0.identity != .reference })
        XCTAssertNil(real.note)
    }

    func testMalformedStoredEntryCannotTrapWhileValidating() {
        var bytes = ipa()
        // local Info.plist storage size smaller than central-directory declaration
        if let cd = bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02])) {
            let off = cd.lowerBound
            bytes.replaceSubrange((off + 20)..<(off + 24), with: le32(1))
        }
        XCTAssertThrowsError(try validate(bytes))
    }

    func testDNSGuardRejectsNonPublicAndMixedFamilies() {
        for ip in ["127.0.0.1", "10.0.0.1", "169.254.169.254", "100.64.0.1",
                   "192.168.0.1", "172.16.0.1", "198.18.0.1", "192.0.2.1",
                   "::1", "fc00::1", "fe80::1", "::ffff:127.0.0.1", "2001:db8::1",
                   "224.0.0.1", "0.0.0.0"] {
            XCTAssertFalse(DiscoveryDNSPolicy.publicAddress(ip), ip)
        }
        XCTAssertTrue(DiscoveryDNSPolicy.publicAddress("8.8.8.8"))
        XCTAssertTrue(DiscoveryDNSPolicy.publicAddress("2606:4700:4700::1111"))
    }

    private struct PageOnlyHTTP: DiscoveryHTTP {
        func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
            if url.host == "itunes.apple.com" { return (Data(#"{"results":[]}"#.utf8), 200) }
            return (Data(#"{"results":[{"name":"WhatsApp","pageURL":"https://example.com/whatsapp"},{"name":"WhatsApp","pageURL":"https://x.com/whatsapp"}]}"#.utf8), 200)
        }
    }
    private struct TestToken: DiscoveryTokenProvider {
        func token(forceRefresh: Bool) async throws -> String { "fixture" }
    }
    func testPageOnlyAndSocialOutcomesNeverDisplayReferenceCards() async {
        let outcome = await DiscoveryEngine.run(input: "WhatsApp", sources: [],
            web: .init(projectURL: u("https://backend.example.com"), publishableKey: "public-test"),
            auth: TestToken(), http: PageOnlyHTTP(), verifier: RejectVerifier())
        XCTAssertEqual(outcome.candidates, [])
        XCTAssertEqual(outcome.note, "ما لقيت IPA لهالتطبيق")
    }

}
