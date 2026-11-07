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
    func testTurningOffKeepsPendingAndAttemptState() {
        let p = make(); p.enabled = true
        p.recordAttempt(build: 6, now: t0)
        p.enabled = false; p.reset()
        p.enabled = true   // OFF then ON while install still pending
        XCTAssertFalse(p.shouldInstall(build: 6, current: 5, now: t0.addingTimeInterval(60)))
    }
    func testOffNeverResetsAttemptCap() {
        let p = make(); p.enabled = true
        var t = t0
        for _ in 0..<3 {
            p.recordAttempt(build: 6, now: t); p.recordFailure(now: t)
            p.enabled = false; p.reset(); p.enabled = true
            t = t.addingTimeInterval(7 * 3600)
        }
        XCTAssertFalse(p.shouldInstall(build: 6, current: 5, now: t))
        XCTAssertTrue(p.shouldInstall(build: 7, current: 5, now: t), "new version resets")
    }
    func testRelaunchSharesPersistedState() {
        let d = UserDefaults(suiteName: "au-\(UUID().uuidString)")!
        let a = AutoUpdatePolicy(defaults: d); a.enabled = true
        a.recordCheck(now: t0); a.recordAttempt(build: 6, now: t0)
        let b = AutoUpdatePolicy(defaults: d)   // relaunch
        XCTAssertFalse(b.shouldCheck(now: t0.addingTimeInterval(60)))
        XCTAssertFalse(b.shouldInstall(build: 6, current: 5, now: t0.addingTimeInterval(60)))
    }
    func testRepeatedForegroundChecksAreThrottled() {
        let p = make(); p.enabled = true
        var allowed = 0
        for i in 0..<20 {
            let now = t0.addingTimeInterval(Double(i) * 30)
            if p.shouldCheck(now: now) { allowed += 1; p.recordCheck(now: now) }
        }
        XCTAssertEqual(allowed, 1)
    }
}
