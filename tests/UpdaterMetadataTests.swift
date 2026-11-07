import XCTest
@testable import Mirsa

final class UpdaterMetadataTests: XCTestCase {
    func testStrictNumericBuilds() {
        XCTAssertFalse(UpdaterMetadata.isNewer(remote: "1.3.2", installed: "1.3.2"))
        XCTAssertFalse(UpdaterMetadata.isNewer(remote: "1.3.1", installed: "1.3.2"))
        XCTAssertTrue(UpdaterMetadata.isNewer(remote: "1.3.10", installed: "1.3.9"))
        XCTAssertTrue(UpdaterMetadata.isNewer(remote: "2.89.1", installed: "1.3.2"))
        XCTAssertFalse(UpdaterMetadata.isNewer(remote: "1.3.2", installed: "2.89.1"))
        XCTAssertFalse(UpdaterMetadata.isNewer(remote: "2.0", installed: "2"))
        for invalid in ["build-100", "1.3.99-beta", "test123", "", "1..2", "1.2.3.4", "18446744073709551616"] {
            XCTAssertFalse(UpdaterMetadata.isNewer(remote: invalid, installed: "1"))
            XCTAssertFalse(UpdaterMetadata.isNewer(remote: "9", installed: invalid))
        }
        XCTAssertFalse(UpdaterMetadata.isNewer(remote: nil, installed: "1"))
        XCTAssertTrue(UpdaterMetadata.isNewer(remote: "18446744073709551615", installed: "2"))
    }
    func testOnlyCuratedLocaleNotes() {
        let body = #"{"releaseNotes":{"en":"Better installation progress.","ar":"تحسين عرض تقدّم التثبيت."}}"#
        XCTAssertEqual(UpdaterMetadata.notes(body: body, language: "ar-DE"), "تحسين عرض تقدّم التثبيت.")
        XCTAssertEqual(UpdaterMetadata.notes(body: body, language: "en"), "Better installation progress.")
        XCTAssertNil(UpdaterMetadata.notes(body: body, language: "de"))
        XCTAssertNil(UpdaterMetadata.notes(body: "Make actual software keyboard snapshots...", language: "en"))
        XCTAssertNil(UpdaterMetadata.notes(body: nil, language: "ar"))
        XCTAssertNil(UpdaterMetadata.notes(body: #"{"releaseNotes":{"en":"English only"}}"#, language: "ar"))
        XCTAssertNil(UpdaterMetadata.notes(body: #"{"releaseNotes":{"ar":" "}}"#, language: "ar"))
    }
}
