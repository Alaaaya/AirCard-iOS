import XCTest
@testable import Mirsa

final class PersonalProjectFolderTests: XCTestCase {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("folder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testMissingDirectoryIsCreatedInOwnDocumentsProject() throws {
        let documents = try sandbox()
        let id = UUID()
        let root = try PersonalProjectFolder.directory(documents: documents, id: id)
        XCTAssertEqual(root, documents.appendingPathComponent("Projects", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true))
        XCTAssertTrue(try PersonalProjectFolder.contents(of: root, in: root).isEmpty)
        XCTAssertEqual(try PersonalProjectFolder.directory(documents: documents, id: id, create: false), root)
        XCTAssertThrowsError(try PersonalProjectFolder.directory(documents: documents, id: UUID(), create: false))
    }
    func testNamesWithSpacesUnicodeAndReservedURLCharactersStayInProject() throws {
        let root = try PersonalProjectFolder.directory(documents: sandbox(), id: UUID())
        let file = root.appendingPathComponent("ملف Mirsa #1% &.ipa")
        try Data("fixture".utf8).write(to: file)
        XCTAssertEqual(try PersonalProjectFolder.contents(of: root, in: root), [file])
        XCTAssertEqual(try PersonalProjectFolder.validated(file, in: root), file)
        XCTAssertEqual(URL(string: file.absoluteString), file)
    }
    func testTraversalSiblingPrefixAndSymlinkEscapeRejected() throws {
        let documents = try sandbox()
        let root = try PersonalProjectFolder.directory(documents: documents, id: UUID())
        let outside = documents.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        XCTAssertThrowsError(try PersonalProjectFolder.validated(outside, in: root))
        XCTAssertThrowsError(try PersonalProjectFolder.validated(URL(fileURLWithPath: root.path + "/../outside.txt"), in: root))
        let sibling = URL(fileURLWithPath: root.path + "-other/file")
        XCTAssertThrowsError(try PersonalProjectFolder.validated(sibling, in: root))
        let link = root.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try PersonalProjectFolder.validated(link, in: root))
        XCTAssertTrue(try PersonalProjectFolder.contents(of: root, in: root).isEmpty)
        let sub = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: documents)
        XCTAssertThrowsError(try PersonalProjectFolder.contents(of: sub, in: root))
    }
    func testSymlinkProjectRootAndDanglingLinkAreRejected() throws {
        let documents = try sandbox()
        let elsewhere = try sandbox()
        let projects = documents.appendingPathComponent("Projects")
        try FileManager.default.createSymbolicLink(at: projects, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try PersonalProjectFolder.directory(documents: documents, id: UUID()))
        try FileManager.default.removeItem(at: projects)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false)
        let id = UUID()
        try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent(id.uuidString),
                                                   withDestinationURL: elsewhere.appendingPathComponent("missing"))
        XCTAssertThrowsError(try PersonalProjectFolder.directory(documents: documents, id: id))
    }
    func testStructuredCertificateCNWithCommaMultivaluedRDNAndUnicode() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "escaped", withExtension: "der", subdirectory: "CertificateLabels")
            ?? Bundle(for: Self.self).url(forResource: "escaped", withExtension: "der"))
        XCTAssertEqual(PersonalCertificateLabel.name(certificate: try Data(contentsOf: url)), "فريق Mirsa, Example")
    }
    func testMissingCNAndMalformedCertificateUseFriendlyFallbackNotRawDN() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "missing", withExtension: "der", subdirectory: "CertificateLabels")
            ?? Bundle(for: Self.self).url(forResource: "missing", withExtension: "der"))
        XCTAssertEqual(PersonalCertificateLabel.name(certificate: try Data(contentsOf: url)), PersonalCertificateLabel.fallback)
        XCTAssertEqual(PersonalCertificateLabel.name(certificate: nil), PersonalCertificateLabel.fallback)
        XCTAssertEqual(PersonalCertificateLabel.name(certificate: Data("CN=raw,OU=never display".utf8)), PersonalCertificateLabel.fallback)
    }
}
