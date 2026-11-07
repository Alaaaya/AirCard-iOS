import XCTest
@testable import Mirsa

final class BundleFileManagerTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bfm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func makeBundle(_ name: String = "orig.app", format: PropertyListSerialization.PropertyListFormat = .xml) throws -> URL {
        let app = tmp.appendingPathComponent(name)
        let fm = FileManager.default
        try fm.createDirectory(at: app.appendingPathComponent("Frameworks/X.framework"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.a.b", "CFBundleExecutable": "Main", "CFBundleVersion": "1", "Flag": true, "Count": 3]
        try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0]).write(to: app.appendingPathComponent("Main"))
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0, 1]).write(to: app.appendingPathComponent("Frameworks/X.framework/X"))
        try Data("hello".utf8).write(to: app.appendingPathComponent("Assets/a.txt"))
        return app
    }
    private func manager(_ app: URL) throws -> BundleFileManager {
        try BundleFileManager(root: app, stagingDirectory: tmp.appendingPathComponent("stage-\(UUID().uuidString)"))
    }
    private func copy(_ app: URL) throws -> URL {
        let c = tmp.appendingPathComponent("ws-\(UUID().uuidString)/work.app")
        try FileManager.default.createDirectory(at: c.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: c); return c
    }

    func testBinaryPlistRoundtripKeepsFormatAndTypes() throws {
        let app = try makeBundle(format: .binary)
        var doc = try PlistDocument(data: Data(contentsOf: app.appendingPathComponent("Info.plist")))
        XCTAssertEqual(doc.format, .binary)
        try doc.setScalar(at: [.key("Count")], text: "7")
        try doc.setScalar(at: [.key("Flag")], text: "false")
        let out = try doc.serialized()
        XCTAssertTrue(out.starts(with: Data("bplist00".utf8)))
        let back = try PlistDocument(data: out)
        XCTAssertEqual(back.value(at: [.key("Count")]) as? Int, 7)
        XCTAssertEqual(PlistDocument.typeName(back.value(at: [.key("Flag")])!), "bool")
    }
    func testXMLPlistStaysXMLAndTypeMismatchRejected() throws {
        let app = try makeBundle()
        var doc = try PlistDocument(data: Data(contentsOf: app.appendingPathComponent("Info.plist")))
        XCTAssertThrowsError(try doc.setScalar(at: [.key("Count")], text: "abc"))
        XCTAssertThrowsError(try doc.setScalar(at: [.key("Flag")], text: "maybe"))
        XCTAssertTrue(String(decoding: try doc.serialized(), as: UTF8.self).contains("<?xml"))
        let viaText = try PlistDocument(xmlText: try doc.xmlText(), preserving: .binary)
        XCTAssertTrue(try viaText.serialized().starts(with: Data("bplist00".utf8)))
    }
    func testInvalidPlistTextRejectedAndDepthBounded() throws {
        XCTAssertThrowsError(try PlistDocument(xmlText: "<plist><dict>", preserving: .xml))
        var s = "<string>x</string>"
        for _ in 0..<40 { s = "<array>\(s)</array>" }
        XCTAssertThrowsError(try PlistDocument(xmlText: "<?xml version=\"1.0\"?><plist version=\"1.0\">\(s)</plist>", preserving: .xml))
    }
    func testTraversalAndSymlinkRejected() throws {
        let app = try makeBundle()
        for bad in ["../x", "a/../b", "/etc", "a//b", "a\\b", "./a"] { XCTAssertThrowsError(try BundlePath.components(bad), bad) }
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Assets/link"), withDestinationURL: tmp)
        XCTAssertThrowsError(try BundlePath.resolve("Assets/link/x", in: app))
        let m = try manager(app)
        XCTAssertThrowsError(try m.stageDelete("../orig.app"))
        XCTAssertThrowsError(try m.stageRename("Assets/a.txt", to: "../b"))
        XCTAssertThrowsError(try m.entry("Assets/link"))
    }
    func testProtectedItemsCannotBeStaged() throws {
        let m = try manager(try makeBundle())
        XCTAssertThrowsError(try m.stageDelete("Main"))
        XCTAssertThrowsError(try m.stageRename("Info.plist", to: "x.plist"))
        XCTAssertThrowsError(try m.stageDelete("Frameworks/X.framework"))
        XCTAssertThrowsError(try m.stageDelete("Frameworks"))
        XCTAssertThrowsError(try m.stageDelete("Frameworks/X.framework/X"))
        XCTAssertNoThrow(try m.stageDelete("Assets/a.txt"))
    }
    func testInfoPlistGuardBlocksExecutableChange() throws {
        let app = try makeBundle(); let m = try manager(app)
        var doc = try PlistDocument(data: Data(contentsOf: app.appendingPathComponent("Info.plist")))
        try doc.setScalar(at: [.key("CFBundleExecutable")], text: "Other")
        XCTAssertThrowsError(try m.stageWrite("Info.plist", plist: doc))
        var ok = try PlistDocument(data: Data(contentsOf: app.appendingPathComponent("Info.plist")))
        try ok.setScalar(at: [.key("CFBundleVersion")], text: "2")
        XCTAssertNoThrow(try m.stageWrite("Info.plist", plist: ok))
    }
    func testStagedOpsDoNotMutateOriginalAndApplyToWorkspace() throws {
        let app = try makeBundle(); let m = try manager(app)
        let src = tmp.appendingPathComponent("new.png"); try Data("png".utf8).write(to: src)
        try m.stageRename("Assets/a.txt", to: "b.txt")
        try m.stageImport(from: src, intoDirectory: "Assets")
        try m.stageWrite("Assets/b.txt", text: "edited")
        XCTAssertEqual(try m.list("Assets").map(\.name), ["b.txt", "new.png"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Assets/a.txt").path))
        let ws = try copy(app)
        try m.apply(to: ws)
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("Assets/b.txt")), "edited")
        XCTAssertEqual(try Data(contentsOf: ws.appendingPathComponent("Assets/new.png")), Data("png".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("Assets/a.txt").path))
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("Assets/a.txt")), "hello")
    }
    func testApplyRollsBackOnFailureAndRejectsOriginalAsWorkspace() throws {
        let app = try makeBundle(); let m = try manager(app)
        try m.stageDelete("Assets/a.txt")
        let ws = try copy(app)
        try FileManager.default.removeItem(at: ws.appendingPathComponent("Assets")) // second op will fail
        var ov = m.overlay; ov.ops.append(.delete(path: "Main")) // protected -> fails after first op
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: ws.appendingPathComponent("Assets/a.txt"))
        XCTAssertThrowsError(try BundleStagingApplier.apply(ov, blobs: m.stagingDirectory, original: app, to: ws))
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("Assets/a.txt")), "hello")
        XCTAssertThrowsError(try m.apply(to: app))
    }
    func testDuplicateAndMissingPathsRejected() throws {
        let m = try manager(try makeBundle())
        let src = tmp.appendingPathComponent("a.txt"); try Data("x".utf8).write(to: src)
        XCTAssertThrowsError(try m.stageImport(from: src, intoDirectory: "Assets"))
        XCTAssertThrowsError(try m.stageDelete("Assets/none"))
        try m.stageDelete("Assets/a.txt")
        XCTAssertThrowsError(try m.stageDelete("Assets/a.txt"))
        XCTAssertNoThrow(try m.stageImport(from: src, intoDirectory: "Assets"))
    }
    func testTextAndBinaryDetectionAndLimits() throws {
        let app = try makeBundle(); let m = try manager(app)
        XCTAssertEqual(try m.entry("Main").kind, .binary)
        XCTAssertEqual(try m.entry("Assets/a.txt").kind, .text)
        XCTAssertEqual(try m.entry("Info.plist").kind, .plist)
        try Data(repeating: 65, count: BundleLimits.maxTextBytes + 1).write(to: app.appendingPathComponent("Assets/big.txt"))
        XCTAssertThrowsError(try m.read("Assets/big.txt"))
        XCTAssertThrowsError(try m.stageWrite("Main", data: Data("x".utf8)))
    }
    func testOverlayCodableRoundtripAndUnstage() throws {
        let m = try manager(try makeBundle())
        try m.stageRename("Assets/a.txt", to: "b.txt")
        try m.stageWrite("Assets/b.txt", text: "z")
        let data = try JSONEncoder().encode(m.overlay)
        XCTAssertEqual(try JSONDecoder().decode(BundleOverlay.self, from: data), m.overlay)
        m.unstage(at: 0) // rename removed => dependent edit dropped
        XCTAssertTrue(m.overlay.isEmpty)
    }
}
