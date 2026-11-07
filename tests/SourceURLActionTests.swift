import XCTest
#if canImport(DiscoveryKit)
@testable import DiscoveryKit
#else
@testable import Mirsa
#endif

@MainActor
final class SourceURLActionTests: XCTestCase {
    func testValidStoredURLs() {
        XCTAssertEqual(SourceURLAction.shareableURL("https://example.com/repo.json")?.absoluteString, "https://example.com/repo.json")
        XCTAssertEqual(SourceURLAction.shareableURL("  http://example.com/a?b=1 ")?.absoluteString, "http://example.com/a?b=1")
    }
    func testInvalidRejected() {
        for bad in ["", "   ", "example.com", "My Source", "javascript:alert(1)", "file:///etc/passwd", "altstore://source?url=https://a.b", "https://", "https://user:pw@example.com/x", "https://user@example.com/x"] {
            XCTAssertNil(SourceURLAction.shareableURL(bad), bad)
        }
    }
    func testCopyWritesPasteboardOnlyForValid() {
        UIPasteboard.general.string = "before"
        SourceURLAction.copy("not a url")
        XCTAssertEqual(UIPasteboard.general.string, "before")
        SourceURLAction.copy("https://example.com/repo.json")
        XCTAssertEqual(UIPasteboard.general.string, "https://example.com/repo.json")
    }
    func testDisplayNameNeverUsed() {
        let src = RepoSource(url: "https://example.com/r.json", name: "Pretty Name")
        XCTAssertEqual(SourceURLAction.shareableURL(src.url)?.absoluteString, "https://example.com/r.json")
    }
}
