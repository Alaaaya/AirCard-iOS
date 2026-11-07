import XCTest
#if canImport(DiscoveryKit)
@testable import DiscoveryKit
#else
@testable import Mirsa
#endif

final class MirsaCrashTelemetryTests: XCTestCase {
    private let payload = #"{"procName":"Foo","bundleID":"com.x.foo","exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"faultingThread":0,"usedImages":[{"name":"Foo","uuid":"AAAAAAAA-0000-0000-0000-000000000000"}],"threads":[{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":42,"symbol":"main"},{"imageIndex":0,"imageOffset":7}]}]}"#
    private let header = #"{"app_name":"Foo","app_version":"1.2","incident_id":"INC-1","timestamp":"2026-11-07 10:00:00.000 +0100"}"#

    func testHeaderNewlinePayload() throws {
        let r = try MirsaCrashParser.parse(Data((header + "\n" + payload).utf8))
        XCTAssertEqual(r.bundleID, "com.x.foo"); XCTAssertEqual(r.id, "INC-1"); XCTAssertEqual(r.signal, "SIGABRT")
        XCTAssertEqual(r.frames.count, 2); XCTAssertEqual(r.frames[0].symbol, "main"); XCTAssertNil(r.frames[1].symbol)
        XCTAssertNotNil(r.date); XCTAssertEqual(r.version, "1.2")
    }
    func testSingleJSON() throws {
        let r = try MirsaCrashParser.parse(Data(payload.utf8))
        XCTAssertEqual(r.appName, "Foo"); XCTAssertEqual(r.crashedThread, 0)
    }
    func testMalformedAndBounds() {
        XCTAssertThrowsError(try MirsaCrashParser.parse(Data()))
        XCTAssertThrowsError(try MirsaCrashParser.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try MirsaCrashParser.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try MirsaCrashParser.parse(Data(count: MirsaCrashParser.maxBytes + 1)))
        XCTAssertThrowsError(try MirsaCrashParser.parse(Data([0xFF, 0xFE, 0x7B])))
        let deep = String(repeating: "[", count: 60) + String(repeating: "]", count: 60)
        XCTAssertThrowsError(try MirsaCrashParser.parse(Data(("{\"procName\":\"a\",\"x\":" + deep + "}").utf8))) { XCTAssertEqual($0 as? MirsaCrashParseError, .tooDeep) }
    }
    func testRedaction() {
        let s = MirsaRedactor.redact("open https://a.b/c?token=1 mail me@x.com /private/var/mobile/Containers/Data/Application/AAAAAAAA-0000-0000-0000-000000000000/Documents/f /Users/bob/x password=hunter2 symbol -[Foo bar]")
        XCTAssertFalse(s.contains("https://")); XCTAssertFalse(s.contains("me@x.com")); XCTAssertFalse(s.contains("bob"))
        XCTAssertFalse(s.contains("hunter2")); XCTAssertFalse(s.contains("AAAAAAAA")); XCTAssertTrue(s.contains("-[Foo bar]"))
    }
    func testStoreBoundsAndAssociation() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let s = MirsaTelemetryStore(url: u)
        for _ in 0..<(MirsaTelemetryStore.maxLaunches + 20) { s.recordLaunch(bundleID: "a", source: .loader) }
        XCTAssertEqual(s.launches(for: "a").count, MirsaTelemetryStore.maxLaunches)
        let r = try s.importCrash(Data(#"{"procName":"Z","exception":{"type":"EXC_BAD_ACCESS"}}"#.utf8))
        XCTAssertEqual(s.unassociatedCrashes().count, 1)
        s.associate(crashID: r.id, bundleID: "z")
        XCTAssertEqual(s.crashes(for: "z").count, 1); XCTAssertEqual(MirsaTelemetryStore(url: u).crashes(for: "z").count, 1)
        s.clear(bundleID: "z"); XCTAssertTrue(s.crashes(for: "z").isEmpty)
    }
}
