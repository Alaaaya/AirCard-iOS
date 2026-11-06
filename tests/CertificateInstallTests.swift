import XCTest
@testable import Mirsa

final class CertificateInstallTests: XCTestCase {
    func testStageRejectsMissingAndNonIPA() {
        let dir = FileManager.default.temporaryDirectory
        XCTAssertThrowsError(try CertificateInstall.stageSignedApp(ipa: dir.appendingPathComponent("none.ipa"), in: dir))
        let txt = dir.appendingPathComponent("x-\(UUID().uuidString).txt")
        try? Data("x".utf8).write(to: txt)
        defer { try? FileManager.default.removeItem(at: txt) }
        XCTAssertThrowsError(try CertificateInstall.stageSignedApp(ipa: txt, in: dir))
    }

    func testRetainedMessageNamesFile() {
        let url = URL(fileURLWithPath: "/tmp/App-signed.ipa")
        let m = CertificateInstall.retainedMessage(SideloadError.message("boom"), url)
        XCTAssertTrue(m.contains("boom"))
        XCTAssertTrue(m.contains("App-signed.ipa"))
    }

    func testRetainedFailureCarriesURL() {
        let url = URL(fileURLWithPath: "/tmp/a.ipa")
        if case CertificateInstall.Failure.retained(_, let u) = CertificateInstall.Failure.retained("m", signedURL: url) {
            XCTAssertEqual(u, url)
        } else { XCTFail() }
    }
}
