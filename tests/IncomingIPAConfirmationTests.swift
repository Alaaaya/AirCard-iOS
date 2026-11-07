import XCTest
@testable import Mirsa

@MainActor
final class IncomingIPAConfirmationTests: XCTestCase {
    func testPresentationAndCancelNeverImportSignOrInstall() {
        var cancels = 0, imports = 0, signs = 0
        let view = IncomingIPAConfirmationSheet(
            url: URL(fileURLWithPath: "/fixture.ipa"), filename: "fixture.ipa",
            onCancel: { cancels += 1 },
            onImportProject: { _ in imports += 1 },
            onSignInstall: { _, _ in signs += 1 })
        XCTAssertEqual(imports, 0)
        XCTAssertEqual(signs, 0)
        XCTAssertNil(view.onDirectInstall, "No eligibility may be inferred from signature presence")
        view.onCancel()
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(imports, 0)
        XCTAssertEqual(signs, 0)
    }
    func testPresenceIsNotEligibilityOrTrustAndMissingProfileStaysMissing() throws {
        // Use encoder-safe construction to avoid embedding identity/profile secrets.
        let data = try JSONSerialization.data(withJSONObject: [
            "signaturePresent": true,
            "entitlements": [["key":"com.apple.security.application-groups", "value":"[\"group.fixture\"]"]]
        ])
        let parsed = try JSONDecoder().decode(IncomingSignature.self, from: data)
        XCTAssertEqual(parsed.signaturePresent, true)
        XCTAssertNil(parsed.embeddedProfile)
        XCTAssertNil(parsed.profileUnavailable)
        XCTAssertEqual(parsed.entitlements.first?.key, "com.apple.security.application-groups")
    }
    func testUnknownSignatureAndUnavailableEntitlementsDoNotBecomeUnsigned() throws {
        let data = Data(#"{"signaturePresent":null,"entitlements":[],"entitlementsUnavailable":true}"#.utf8)
        let parsed = try JSONDecoder().decode(IncomingSignature.self, from: data)
        XCTAssertNil(parsed.signaturePresent)
        XCTAssertEqual(parsed.entitlementsUnavailable, true)
        XCTAssertTrue(parsed.entitlements.isEmpty)
    }
    func testPreviewRejectsSymlinkBeforeExtraction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.ipa")
        let link = root.appendingPathComponent("link.ipa")
        try Data("not an IPA".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try IncomingIPAInspection.load(link))
        XCTAssertEqual(try Data(contentsOf: original), Data("not an IPA".utf8))
    }
}
