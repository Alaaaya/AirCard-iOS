import XCTest
@testable import AirCard_iOS

final class OpenInIPATests: XCTestCase {
    private func input(_ name: String, bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(name)
        try bytes.write(to: file)
        return file
    }

    func testCopyIsIndependentAndCleanupPreservesSource() throws {
        let source = try input("Example.IPA", bytes: Data([0x50, 0x4b, 3, 4]))
        let copy = try OpenInIPA.snapshot(source)
        XCTAssertNotEqual(copy, source)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
        OpenInIPA.remove(copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testRejectsRemoteAndWrongExtension() throws {
        XCTAssertThrowsError(try OpenInIPA.snapshot(URL(string: "https://example.com/app.ipa")!))
        let source = try input("app.zip", bytes: Data([1]))
        XCTAssertThrowsError(try OpenInIPA.snapshot(source))
    }

    func testRejectsEmptyAndDirectory() throws {
        let empty = try input("empty.ipa", bytes: Data())
        XCTAssertThrowsError(try OpenInIPA.snapshot(empty))
        let folder = empty.deletingLastPathComponent().appendingPathComponent("folder.ipa")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try OpenInIPA.snapshot(folder))
    }

    func testRejectsSymbolicLink() throws {
        let source = try input("actual.ipa", bytes: Data([1]))
        let link = source.deletingLastPathComponent().appendingPathComponent("link.ipa")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try OpenInIPA.snapshot(link))
    }

    func testCleanupCannotDeleteArbitraryFile() throws {
        let source = try input("app.ipa", bytes: Data([1]))
        OpenInIPA.remove(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
