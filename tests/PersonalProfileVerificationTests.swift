import XCTest
@testable import Mirsa

final class PersonalProfileVerificationTests: XCTestCase {
    func testMissingOrMalformedStatusNeverVerified() {
        XCTAssertFalse(PersonalProfileVerification.parse([:]).isVerified)
        XCTAssertFalse(PersonalProfileVerification.parse(["profile_verification": "verified"]).isVerified)
        XCTAssertFalse(PersonalProfileVerification.parse(["profile_verification": "other", "warnings": []]).isVerified)
        XCTAssertFalse(PersonalProfileVerification.parse(["profile_verification": "verified", "warnings": [["code": "x"]]]).isVerified)
        XCTAssertFalse(PersonalProfileVerification.unknown.warningText.isEmpty)
    }
    func testWarningsAndIndicesSurvivePersistence() throws {
        let value = PersonalProfileVerification.parse(["profile_verification": "unverified", "warnings": [
            ["code": "profile_cms_unverified", "message": "تعذر التحقق، فيك تكمّل.", "profile_index": 0]]])
        XCTAssertFalse(value.isVerified)
        let restored = try JSONDecoder().decode(PersonalProfileVerification.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(value, restored)
        XCTAssertEqual(restored.warnings.first?.profile_index, 0)
    }
    func testExplicitVerifiedRequiresNoWarnings() {
        XCTAssertTrue(PersonalProfileVerification.parse(["profile_verification": "verified", "warnings": []]).isVerified)
        XCTAssertFalse(PersonalProfileVerification.parse(["profile_verification": "unverified", "warnings": []]).isVerified)
    }
    func testLegacyVaultMaterialDecodesWithoutVerification() throws {
        let json = #"{"p12":"AA==","password":"","profile":"AA=="}"#
        let material = try JSONDecoder().decode(PersonalIdentityVault.Material.self, from: Data(json.utf8))
        XCTAssertNil(material.verification)
    }
}
