import XCTest
@testable import Mirsa

final class InstallErrorTextTests: XCTestCase {
    func testOnlyConfirmedSourceAbsenceSuggestsRedownload() {
        XCTAssertEqual(InstallErrorText.sanitize("MIRSA_SOURCE_IPA_MISSING", arabic: false),
                       "The app file is missing. Download it again.")
        XCTAssertEqual(InstallErrorText.sanitize("MIRSA_SOURCE_IPA_MISSING", arabic: true),
                       "ملف التطبيق مو موجود، نزّله من جديد")
        let error = "Install failed: No such file or directory (os error 2)\n/Users/runner/.cargo/registry/src/isideload-0.5.2/src/sideload/install.rs:162"
        for arabic in [true, false] {
            let safe = InstallErrorText.sanitize(error, arabic: arabic)
            XCTAssertFalse(safe.contains("runner"))
            XCTAssertFalse(safe.contains("isideload"))
            XCTAssertFalse(safe.contains("Download"))
            XCTAssertFalse(safe.contains("نزّله"))
            XCTAssertTrue(safe.contains("os error 2"))
        }
    }
    func testPreparationAndOtherENOENTKeepTheirOwnStage() {
        let error = "Preparing app snapshot: No such file or directory (os error 2)"
        let en = InstallErrorText.sanitize(error, arabic: false)
        XCTAssertTrue(en.hasPrefix("Preparing app snapshot:"))
        XCTAssertFalse(en.contains("Download"))
        XCTAssertTrue(InstallErrorText.sanitize(error, arabic: true).contains("تجهيز نسخة التثبيت"))
    }
    func testPathRedactionPreservesUsefulCause() {
        let raw = "Signing failed: permission denied /home/kit/private/Test.app and /private/var/mobile/tmp/output"
        let safe = InstallErrorText.sanitize(raw, arabic: false)
        XCTAssertTrue(safe.contains("Signing failed: permission denied"))
        XCTAssertFalse(safe.contains("/home/"))
        XCTAssertFalse(safe.contains("/private/"))
        XCTAssertEqual(InstallErrorText.sanitize(safe, arabic: false), safe)
    }
    func testOtherInstallCausesRemainUseful() {
        let raw = "Install failed: provisioning profile expired (0xe8008015)"
        XCTAssertEqual(InstallErrorText.sanitize(raw, arabic: false), raw)
    }
}
