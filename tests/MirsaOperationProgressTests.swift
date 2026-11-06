import XCTest
@testable import Mirsa

@MainActor
final class MirsaOperationProgressTests: XCTestCase {
    func testUnknownProgressAndValidatedAssociation() {
        let state = MirsaOperationProgress()
        let token = state.begin(phase: .downloading)
        XCTAssertNil(state.entries[token]?.appID)
        XCTAssertNil(state.entries[token]?.fraction)
        XCTAssertFalse(state.entries[token]?.canCancel ?? true)
        state.associate(token, appID: "com.example.validated")
        XCTAssertEqual(state.entry(for: "com.example.validated")?.id, token)
        state.update(token, phase: .downloading, fraction: 0.37)
        XCTAssertEqual(state.entries[token]?.fraction, 0.37)
        state.update(token, phase: .preparing)
        XCTAssertNil(state.entries[token]?.fraction)
        state.finish(token)
        state.update(token, phase: .installing, fraction: 0.8)
        XCTAssertTrue(state.entries.isEmpty)
    }

    func testCancellationOnlyDuringCancellableDownload() {
        let state = MirsaOperationProgress()
        var cancelled = 0
        let token = state.begin(appID: "a", phase: .downloading, cancel: { cancelled += 1 })
        XCTAssertTrue(state.entries[token]?.canCancel == true)
        state.cancel(token)
        state.cancel(token)
        XCTAssertEqual(cancelled, 1)
        XCTAssertTrue(state.entries.isEmpty)
        let signing = state.begin(appID: "a", phase: .downloading, cancel: { cancelled += 1 })
        state.update(signing, phase: .signing)
        state.cancel(signing)
        XCTAssertEqual(cancelled, 1)
        XCTAssertNotNil(state.entries[signing])
        state.finish(signing)
    }

    func testFractionsClampAndRejectNonFiniteValues() {
        let state = MirsaOperationProgress()
        let token = state.begin(appID: "a", phase: .installing)
        state.update(token, phase: .installing, fraction: .nan)
        XCTAssertNil(state.entries[token]?.fraction)
        state.update(token, phase: .installing, fraction: .infinity)
        XCTAssertNil(state.entries[token]?.fraction)
        state.update(token, phase: .installing, fraction: -2)
        XCTAssertEqual(state.entries[token]?.fraction, 0)
        state.update(token, phase: .installing, fraction: 4)
        XCTAssertEqual(state.entries[token]?.fraction, 1)
        state.finish(token)
    }

    func testOldTokenCannotMutateNextOperation() {
        let state = MirsaOperationProgress()
        let old = state.begin(appID: "a", phase: .downloading)
        state.finish(old)
        let next = state.begin(appID: "a", phase: .installing)
        state.update(old, phase: .downloading, fraction: 0.9)
        state.finish(old)
        XCTAssertEqual(state.entry(for: "a")?.id, next)
        XCTAssertNil(state.entries[next]?.fraction)
        state.finish(next)
    }

    func testFeedbackDeduplicationWithoutPlayingFeedback() {
        let feedback = MirsaCompletionFeedback()
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(feedback.consumeCompletion(first))
        XCTAssertFalse(feedback.consumeCompletion(first))
        XCTAssertTrue(feedback.consumeCompletion(second))
        XCTAssertFalse(feedback.consumeCompletion(second))
        XCTAssertFalse(feedback.consumeCompletion(first))
    }

    func testFeedbackDeduplicationStorageIsBounded() {
        let feedback = MirsaCompletionFeedback()
        let oldest = UUID()
        XCTAssertTrue(feedback.consumeCompletion(oldest))
        for _ in 0..<256 { XCTAssertTrue(feedback.consumeCompletion(UUID())) }
        XCTAssertTrue(feedback.consumeCompletion(oldest))
        XCTAssertFalse(feedback.consumeCompletion(oldest))
    }

    func testCancellationFeedbackClassification() {
        if case .cancelled = MirsaCompletionFeedback.outcome(for: CancellationError()) {} else { XCTFail() }
        if case .cancelled = MirsaCompletionFeedback.outcome(for: URLError(.cancelled)) {} else { XCTFail() }
        if case .failure = MirsaCompletionFeedback.outcome(for: URLError(.timedOut)) {} else { XCTFail() }
    }
}
