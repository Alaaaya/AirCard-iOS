import XCTest
import Foundation
#if canImport(DiscoveryKit)
@testable import DiscoveryKit
#else
@testable import Mirsa
#endif

final class MirsaBrowserPolicyTests: XCTestCase {
    private func u(_ s: String) -> URL { URL(string: s)! }

    func testIPAMimeAndDispositionAreDownloads() {
        let url = u("https://files.example.com/get?id=7")
        XCTAssertEqual(MirsaBrowserPolicy.decide(response: url, mimeType: "application/x-itunes-ipa", contentDisposition: nil, canShow: false), .download(url))
        XCTAssertEqual(MirsaBrowserPolicy.decide(response: url, mimeType: "application/octet-stream",
            contentDisposition: "attachment; filename=\"App.ipa\"", canShow: false), .download(url))
        XCTAssertEqual(MirsaBrowserPolicy.decide(response: url, mimeType: "application/octet-stream",
            contentDisposition: "attachment; filename*=UTF-8''My%20App.ipa", canShow: false), .download(url))
        let direct = u("https://cdn.example.com/a/App.ipa")
        XCTAssertEqual(MirsaBrowserPolicy.decide(response: direct, mimeType: "application/zip", contentDisposition: nil, canShow: false), .download(direct))
    }

    func testHTMLMasqueradingAsIPAStaysAPage() {
        let url = u("https://cloud.example.com/share/App.ipa")
        XCTAssertEqual(MirsaBrowserPolicy.decide(response: url, mimeType: "text/html; charset=utf-8", contentDisposition: nil, canShow: true), .allow)
        XCTAssertEqual(MirsaBrowserPolicy.decide(response: url, mimeType: "text/html", contentDisposition: "attachment; filename=\"x.ipa\"", canShow: true), .allow)
        XCTAssertEqual(MirsaBrowserPolicy.decide(response: url, mimeType: "application/json", contentDisposition: nil, canShow: true), .allow)
    }

    func testOrdinaryNavigationAndUnknownBinaries() {
        let page = u("https://example.com/")
        XCTAssertEqual(MirsaBrowserPolicy.decide(response: page, mimeType: "text/html", contentDisposition: nil, canShow: true), .allow)
        XCTAssertEqual(MirsaBrowserPolicy.decide(response: page, mimeType: "image/png", contentDisposition: nil, canShow: true), .allow)
        // Generic binary without an .ipa name is not an IPA candidate; unshowable => refused, never a WKDownload.
        if case .refuse = MirsaBrowserPolicy.decide(response: page, mimeType: "application/octet-stream",
            contentDisposition: "attachment; filename=\"tool.exe\"", canShow: false) {} else { XCTFail("expected refuse") }
    }

    func testPrivateHostsAndInsecureLinksRefused() {
        for s in ["https://192.168.1.5/App.ipa", "https://localhost/App.ipa", "https://10.0.0.2/a.ipa", "https://[::1]/a.ipa"] {
            if case .refuse = MirsaBrowserPolicy.decide(response: u(s), mimeType: "application/x-itunes-ipa", contentDisposition: nil, canShow: false) {}
            else { XCTFail("should refuse \(s)") }
        }
        if case .refuse = MirsaBrowserPolicy.decide(navigation: u("http://example.com/App.ipa")) {} else { XCTFail("http ipa") }
        if case .refuse = MirsaBrowserPolicy.decide(response: u("http://example.com/x"), mimeType: "application/x-itunes-ipa", contentDisposition: nil, canShow: false) {}
        else { XCTFail("http response") }
        if case .refuse = MirsaBrowserPolicy.decide(response: u("https://user:pw@example.com/x.ipa"), mimeType: nil, contentDisposition: nil, canShow: false) {}
        else { XCTFail("credentials in URL") }
    }

    func testNavigationSchemes() {
        XCTAssertEqual(MirsaBrowserPolicy.decide(navigation: u("https://example.com/a")), .allow)
        XCTAssertEqual(MirsaBrowserPolicy.decide(navigation: u("http://example.com/a")), .allow)
        XCTAssertEqual(MirsaBrowserPolicy.decide(navigation: u("about:blank")), .allow)
        for s in ["itms-services://?action=download-manifest&url=https://x/m.plist", "file:///etc/passwd", "javascript:alert(1)", "mirsa://x"] {
            if case .refuse = MirsaBrowserPolicy.decide(navigation: u(s)) {} else { XCTFail("should refuse \(s)") }
        }
    }

    func testAddressField() {
        XCTAssertEqual(MirsaBrowserPolicy.address(from: "example.com/x")?.absoluteString, "https://example.com/x")
        XCTAssertEqual(MirsaBrowserPolicy.address(from: " https://example.com ")?.scheme, "https")
        XCTAssertNil(MirsaBrowserPolicy.address(from: "javascript:alert(1)"))
        XCTAssertNil(MirsaBrowserPolicy.address(from: "file:///etc/passwd"))
        XCTAssertNil(MirsaBrowserPolicy.address(from: "two words.com"))
        XCTAssertNil(MirsaBrowserPolicy.address(from: ""))
        XCTAssertNil(MirsaBrowserPolicy.address(from: "localhostonly"))
    }

    func testDedupeKeyCollapsesNavigationAndResponse() {
        XCTAssertEqual(MirsaBrowserPolicy.dedupeKey(u("https://Files.Example.com/a.ipa#frag")), MirsaBrowserPolicy.dedupeKey(u("https://files.example.com/a.ipa")))
        XCTAssertNotEqual(MirsaBrowserPolicy.dedupeKey(u("https://files.example.com/a.ipa?x=1")), MirsaBrowserPolicy.dedupeKey(u("https://files.example.com/a.ipa?x=2")))
    }

    func testDispositionParsing() {
        XCTAssertEqual(MirsaBrowserPolicy.dispositionFilename("attachment; filename=a.ipa"), "a.ipa")
        XCTAssertEqual(MirsaBrowserPolicy.dispositionFilename("attachment; filename=\"b c.ipa\"; size=3"), "b c.ipa")
        XCTAssertNil(MirsaBrowserPolicy.dispositionFilename("inline"))
        XCTAssertNil(MirsaBrowserPolicy.dispositionFilename(nil))
    }

    func testDownloaderStillRefusesUnpinnedUnsafeURL() async {
        let d = DiscoveryDownloader()
        do { _ = try await d.download(u("https://127.0.0.1/a.ipa"), expectedBytes: 10) { _ in }; XCTFail("must throw") }
        catch { XCTAssertTrue(error is DiscoveryDownloader.Failure) }
    }
}
