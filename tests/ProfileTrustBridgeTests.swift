import XCTest
@testable import Mirsa

@_silgen_name("mirsa_verify_profile_signer_chain")
private func verifyProfileSigner(_ signer: UnsafePointer<UInt8>?, _ signerLength: Int,
                                 _ chain: UnsafePointer<UInt8>?, _ chainLength: Int) -> Int32

final class ProfileTrustBridgeTests: XCTestCase {
    func testRejectsNullAndOutOfBoundsInputs() {
        XCTAssertEqual(verifyProfileSigner(nil, 0, nil, 0), 0)
        var byte: UInt8 = 0
        withUnsafePointer(to: &byte) { p in
            XCTAssertEqual(verifyProfileSigner(p, 65537, nil, 0), 0)
            XCTAssertEqual(verifyProfileSigner(p, 1, nil, 1), 0)
            XCTAssertEqual(verifyProfileSigner(p, 1, p, 262145), 0)
            XCTAssertEqual(verifyProfileSigner(p, 1, nil, 0), 0)
        }
    }
}
