import XCTest
@testable import Mirsa
final class OwnCertificateDeviceTests: XCTestCase {
    let id="00008110-0012345678901234"
    func testBindingAndLossFailClosed() {
        let value=["udid":id,"binding":"vendor","installation":"local"]
        XCTAssertTrue(OwnCertificateDevice.validRecord(value,vendor:"vendor",installation:"local"))
        XCTAssertFalse(OwnCertificateDevice.validRecord(value,vendor:"other",installation:"local"))
        XCTAssertFalse(OwnCertificateDevice.validRecord(value,vendor:nil,installation:"local"))
        XCTAssertFalse(OwnCertificateDevice.validRecord(value,vendor:"vendor",installation:nil))
        XCTAssertFalse(OwnCertificateDevice.validRecord(value,vendor:"vendor",installation:"new-install"))
        for bad in ["", "invented", "stale"] {
            XCTAssertFalse(OwnCertificateDevice.validRecord(["udid":bad,"binding":"vendor","installation":"local"],vendor:"vendor",installation:"local"))
        }
        XCTAssertFalse(OwnCertificateDevice.validRecord([:],vendor:"vendor",installation:"local"))
    }
}
