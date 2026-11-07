import XCTest
@testable import Mirsa

final class AutoUpdatePolicyTests: XCTestCase {
    private func make() -> AutoUpdatePolicy {
        let d = UserDefaults(suiteName: "au-\(UUID().uuidString)")!
        return AutoUpdatePolicy(defaults: d)
    }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testDefaultOffNeverChecksOrInstalls() {
        let p = make()
        XCTAssertFalse(p.enabled)
        XCTAssertFalse(p.shouldCheck(now: t0))
        XCTAssertFalse(p.shouldInstall(build: 99, current: 1, now: t0))
    }
    func testEnabledChecksAreThrottled() {
        let p = make(); p.enabled = true
        XCTAssertTrue(p.shouldCheck(now: t0))
        p.recordCheck(now: t0)
        XCTAssertFalse(p.shouldCheck(now: t0.addingTimeInterval(60)))
        XCTAssertTrue(p.shouldCheck(now: t0.addingTimeInterval(16 * 60)))
    }
    func testOnlyNewerBuildInstalls() {
        let p = make(); p.enabled = true
        XCTAssertFalse(p.shouldInstall(build: 5, current: 5, now: t0))
        XCTAssertFalse(p.shouldInstall(build: 4, current: 5, now: t0))
        XCTAssertTrue(p.shouldInstall(build: 6, current: 5, now: t0))
    }
    func testPendingInstallBlocksDuplicate() {
        let p = make(); p.enabled = true
        p.recordAttempt(build: 6, now: t0)
        XCTAssertFalse(p.shouldInstall(build: 6, current: 5, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(p.shouldInstall(build: 7, current: 5, now: t0.addingTimeInterval(60)))
    }
    func testBackoffGrowsAndCaps() {
        let p = make(); p.enabled = true
        p.recordAttempt(build: 6, now: t0); p.recordFailure(now: t0)
        XCTAssertFalse(p.shouldCheck(now: t0.addingTimeInterval(10 * 60)))
        let t1 = t0.addingTimeInterval(16 * 60)
        XCTAssertTrue(p.shouldInstall(build: 6, current: 5, now: t1))
        p.recordAttempt(build: 6, now: t1); p.recordFailure(now: t1)
        XCTAssertFalse(p.shouldInstall(build: 6, current: 5, now: t1.addingTimeInterval(20 * 60)))
        let t2 = t1.addingTimeInterval(31 * 60)
        XCTAssertTrue(p.shouldInstall(build: 6, current: 5, now: t2))
        p.recordAttempt(build: 6, now: t2); p.recordFailure(now: t2)
        XCTAssertFalse(p.shouldInstall(build: 6, current: 5, now: t2.addingTimeInterval(7 * 3600)), "max attempts per build")
    }
    func testTurningOffClearsState() {
        let p = make(); p.enabled = true
        p.recordAttempt(build: 6, now: t0); p.recordFailure(now: t0)
        p.enabled = false; p.reset()
        XCTAssertFalse(p.shouldCheck(now: t0.addingTimeInterval(99999)))
        p.enabled = true
        XCTAssertTrue(p.shouldInstall(build: 6, current: 5, now: t0.addingTimeInterval(1)))
    }
}
