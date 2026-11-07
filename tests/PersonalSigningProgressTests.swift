import XCTest
import SwiftUI
@testable import Mirsa

@MainActor
final class PersonalSigningProgressTests: XCTestCase {
    func testMeasuredBundleProgressAndUnknownTotals() {
        XCTAssertNil(PersonalSigningEvent.signing(completed: 0, total: 0).fraction)
        XCTAssertEqual(PersonalSigningEvent.signing(completed: 1, total: 4).fraction, 0.25)
        XCTAssertEqual(PersonalSigningEvent.signing(completed: 4, total: 4).fraction, 1)
    }
    func testInstallCannotClaimSuccessFromEarlyHundredCallback() {
        XCTAssertNil(PersonalSigningEvent.installation(1, stage: "Connecting"))
        XCTAssertNil(PersonalSigningEvent.installation(.nan, stage: "Installing"))
        XCTAssertNil(PersonalSigningEvent.installation(.infinity, stage: "Installing"))
        XCTAssertEqual(PersonalSigningEvent.installation(1, stage: "Installing")?.fraction, 0.99)
        XCTAssertEqual(PersonalSigningEvent.installation(0.37, stage: "Installing")?.fraction, 0.37)
        XCTAssertEqual(PersonalSigningEvent.installation(-1, stage: "Installing")?.fraction, 0)
    }
    func testExpirationCooperativelyStopsAtNextCheckpoint() throws {
        let control = PersonalSigningControl()
        XCTAssertNoThrow(try control.checkpoint())
        control.cancel()
        XCTAssertTrue(control.isCancelled)
        XCTAssertThrowsError(try control.checkpoint())
        control.cancel()
        XCTAssertThrowsError(try control.checkpoint())
    }
    func testCancellationDoesNotLeakToNextOperation() throws {
        let old = PersonalSigningControl()
        old.cancel()
        let next = PersonalSigningControl()
        XCTAssertFalse(next.isCancelled)
        XCTAssertNoThrow(try next.checkpoint())
    }
    /// Real SwiftUI simulator rendering with seeded measured-unit state.
    /// This is not a signing/device or Dynamic Island runtime claim.
    func testArabicMeasuredStageScreenshots() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PersonalUIFixture", withExtension: "zip"))
        let library = PersonalAppsLibrary.shared
        let before = Set(library.apps.map(\.id))
        try await library.add(fixture, signed: false)
        let app = try XCTUnwrap(library.apps.first { !before.contains($0.id) })
        defer { try? library.delete(app) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        defer { window.isHidden = true; original?.makeKey() }
        for stage: PersonalSigningOperation.Stage in [.preparing, .signing, .packaging, .installing] {
            var state = PersonalSigningOperation.State(id: UUID(), projectID: app.id)
            state.stage = stage
            if stage == .signing { state.fraction = 0.25; state.completedUnits = 1; state.totalUnits = 4 }
            if stage == .installing { state.fraction = 0.63 }
            let model = PersonalSigningOperation(initialState: state)
            let host = UIHostingController(rootView:
                PersonalProjectDetailView(app: app, signing: model)
                    .environment(\.layoutDirection, .leftToRight).environment(\.locale, Locale(identifier: "ar"))
                    .preferredColorScheme(.dark))
            window.rootViewController = host; window.makeKeyAndVisible(); window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 400_000_000)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            XCTAssertEqual(image.size.width, 430)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Arabic-signing-progress-\(stage.rawValue)-real-SwiftUI-fixture"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
