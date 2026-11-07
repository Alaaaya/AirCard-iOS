import XCTest
@testable import Mirsa

@MainActor
final class PersonalProjectPerformanceTests: XCTestCase {
    func testHundredImmediateEditsBecomeOneLatestDraftWrite() async throws {
        var outputs: [Data] = []
        let writer = PersonalProjectDraftWriter(delay: 20_000_000) { data, _ in outputs.append(data) }
        var draft = PersonalProjectDraft()
        for index in 0..<100 {
            draft.name = "Edit \(index)"
            writer.schedule(draft, to: URL(fileURLWithPath: "/unused-test-path"))
        }
        XCTAssertTrue(outputs.isEmpty, "Typing must not synchronously encode/write every keystroke")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(PersonalProjectDraft.self, from: XCTUnwrap(outputs.last)).name, "Edit 99")
    }
    func testLeavingOrSigningFlushesLatestEditImmediatelyOnce() async throws {
        var outputs: [Data] = []
        let writer = PersonalProjectDraftWriter(delay: 20_000_000) { data, _ in outputs.append(data) }
        var draft = PersonalProjectDraft()
        draft.bundleID = "com.fixture.latest"
        writer.schedule(draft, to: URL(fileURLWithPath: "/unused-test-path"))
        writer.flush()
        writer.flush()
        XCTAssertEqual(outputs.count, 1)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(outputs.count, 1, "Cancelled debounce must not write again after flush")
        XCTAssertEqual(try JSONDecoder().decode(PersonalProjectDraft.self, from: XCTUnwrap(outputs.last)).bundleID, draft.bundleID)
    }
    func testFileIdentityInvalidatesInspectionAfterRewriteAndReplacement() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inspection-key-\(UUID().uuidString).ipa")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("one".utf8).write(to: url)
        let first = try PersonalProjectInspection.Key(url)
        XCTAssertEqual(first, try PersonalProjectInspection.Key(url))
        try Data("a different length".utf8).write(to: url)
        let changed = try PersonalProjectInspection.Key(url)
        XCTAssertNotEqual(first, changed)
        try FileManager.default.removeItem(at: url)
        try Data("new".utf8).write(to: url)
        XCTAssertNotEqual(changed, try PersonalProjectInspection.Key(url))
    }
    func testInspectionRejectsSymlinkWithoutExtracting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inspection-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real.ipa"), link = root.appendingPathComponent("link.ipa")
        try Data("fixture".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try PersonalProjectInspection.Key(link))
    }
}
