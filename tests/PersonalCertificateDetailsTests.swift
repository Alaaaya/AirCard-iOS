import XCTest
@testable import Mirsa

final class PersonalCertificateDetailsTests: XCTestCase {
    func testBooleanValuesAreNotPresenceChecks() {
        XCTAssertEqual(PersonalCertificateDetailsView.display(false), "false")
        XCTAssertEqual(PersonalCertificateDetailsView.display(true), "true")
    }
    func testArrayValuesRemainReadable() {
        XCTAssertEqual(PersonalCertificateDetailsView.display(["Publish", "Subscribe"]), "Publish, Subscribe")
    }
}
