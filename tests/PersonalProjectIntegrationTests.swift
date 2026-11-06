import XCTest
import SwiftUI
@testable import AirCard_iOS

@MainActor
final class PersonalProjectIntegrationTests: XCTestCase {
    func testURLValidation() throws {
        XCTAssertEqual(try PersonalIPAURL.validate(" https://example.com/test.ipa?token=public ").host, "example.com")
        for link in ["http://example.com/a.ipa", "https://localhost/a.ipa", "https://127.0.0.1/a.ipa",
                     "https://10.0.0.1/a.ipa", "https://172.16.0.1/a.ipa", "https://192.168.1.1/a.ipa",
                     "https://169.254.1.1/a.ipa", "https://[::1]/a.ipa", "https://me:secret@example.com/a.ipa",
                     "https://example.com/file.apk", "https://example.local/a.ipa"] {
            XCTAssertThrowsError(try PersonalIPAURL.validate(link), link)
        }
    }

    func testProjectDraftRoundTripPreservesOrderedTweaks() throws {
        let ids = [UUID(), UUID()]
        var draft = PersonalProjectDraft(name: "Fixture", bundleID: "com.example.fixture", version: "1.0")
        draft.tweakIDs = ids; draft.removeWatchApp = true; draft.fileSharing = true
        let copy = try JSONDecoder().decode(PersonalProjectDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(copy, draft)
        XCTAssertEqual(copy.tweakIDs, ids)
    }

    func testRealSwiftUIArabicSnapshotsAndIPAIcon() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PersonalUIFixture", withExtension: "zip"))
        let library = PersonalAppsLibrary.shared
        let before = Set(library.apps.map(\.id))
        try await library.add(fixture, signed: false)
        let app = try XCTUnwrap(library.apps.first { !before.contains($0.id) })
        defer { try? library.delete(app) }
        let icon = try XCTUnwrap(library.icon(for: app), "The real fixture IPA icon must be extracted, not a placeholder")
        XCTAssertEqual(icon.size.width, 180)
        XCTAssertEqual(icon.size.height, 180)
        try await snapshot(PersonalAppsHub(), name: "Arabic-projects-real-SwiftUI-fixture")
        try await snapshot(NavigationStack { ScrollView { PersonalCertificateView().padding(20) }.background(AuroraBackground()) }, name: "Arabic-certificate-import-real-SwiftUI")
        try await snapshot(PersonalProjectDetailView(app: app), name: "Arabic-project-details-real-SwiftUI-fixture")
    }

    private func snapshot<V: View>(_ view: V, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        let host = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "ar")).environment(\.layoutDirection, .leftToRight))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; original?.makeKey() }
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 800_000_000)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var rendered = false
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered)
        XCTAssertEqual(image.size, CGSize(width: 430, height: 932))
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
