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

    func testTweakChipSnapshotHomeToggleAndHiddenUI() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PersonalUIFixture", withExtension: "zip"))
        let library = PersonalAppsLibrary.shared
        let tweaks = IPATweakLibrary.shared
        let defaults = UserDefaults.standard
        let gridKey = "mirsa.personal.projects.grid"
        let oldGrid = defaults.object(forKey: gridKey)
        let beforeApps = Set(library.apps.map(\.id)), beforeTweaks = Set(tweaks.items.map(\.id))
        // Harmless synthetic bytes named like a dylib; imported as data, never loaded or executed.
        let dylib = FileManager.default.temporaryDirectory.appendingPathComponent("testdylib-\(UUID().uuidString).dylib")
        try Data("not executable fixture".utf8).write(to: dylib)
        defer {
            try? FileManager.default.removeItem(at: dylib)
            for t in tweaks.items where !beforeTweaks.contains(t.id) { try? tweaks.delete(t) }
            for a in library.apps where !beforeApps.contains(a.id) { try? library.delete(a) }
            if let oldGrid { defaults.set(oldGrid, forKey: gridKey) } else { defaults.removeObject(forKey: gridKey) }
        }
        try await library.add(fixture, signed: false)
        let app = try XCTUnwrap(library.apps.first { !beforeApps.contains($0.id) })
        try await tweaks.addFile(dylib)
        let tweak = try XCTUnwrap(tweaks.items.first { !beforeTweaks.contains($0.id) }, "Tweak import must create a real library item; no chip proof without it")
        XCTAssertEqual(tweak.roots, [dylib.lastPathComponent])
        var draft = PersonalProjectDraft(name: "Fixture", bundleID: app.bundleID, version: "1.0")
        draft.tweakIDs = [tweak.id]
        try JSONEncoder().encode(draft).write(to: library.draftURL(app), options: .atomic)
        XCTAssertEqual(try JSONDecoder().decode(PersonalProjectDraft.self, from: Data(contentsOf: library.draftURL(app))).tweakIDs, [tweak.id])
        // Model fixture: real MirsaOperationProgress entries keyed by the library UUID string, rendered by real SwiftUI.
        let progress = MirsaOperationProgress.shared
        let op = progress.begin(appID: app.id.uuidString, phase: .signing)
        defer { progress.finish(op) }
        XCTAssertEqual(progress.entry(for: app.id.uuidString)?.id, op)
        XCTAssertNil(progress.entry(for: app.bundleID), "operations must key by library UUID, not bundleID")
        try await snapshot(PersonalAppsHub(), name: "Personal-ring-indeterminate-fixture")
        progress.update(op, phase: .signing, fraction: 0.5)
        try await snapshot(PersonalAppsHub(), name: "Personal-ring-determinate-fixture")
        let mainOp = progress.begin(appID: "com.example.main", phase: .downloading, cancel: {})
        defer { progress.finish(mainOp) }
        XCTAssertEqual(progress.entry(for: "com.example.main")?.canCancel, true)
        progress.cancel(mainOp)
        XCTAssertNil(progress.entry(for: "com.example.main"), "cancel must clear a cancellable operation")
        defaults.set(false, forKey: gridKey)
        try await snapshot(PersonalAppsHub(), name: "Personal-list-default-tweak-chip-x")
        defaults.set(true, forKey: gridKey)
        try await snapshot(PersonalAppsHub(), name: "Personal-home-toggle-grid")
        try await snapshot(HiddenAppsView(store: HiddenAppsStore.shared) { PersonalHiddenGrid(apps: library.apps, pendingHide: .constant(nil)) }, name: "Arabic-hidden-apps-PIN-UI")
    }

    /// SIMULATOR FIXTURE: seeded real MirsaOperationProgress state rendered by the real AppTile/MirsaHomeScreen.
    /// Not a network download and not a device run.
    func testSimulatorFixtureMainTileRing() async throws {
        let app = ManagedApp(id: "com.example.ringfixture", name: "Ring Fixture", version: "1.0", sizeBytes: 1,
                             location: .container, installedBundleID: nil, expires: nil, signedSerial: nil,
                             wantsNotifications: false, hasExtensions: false, addedAt: Date())
        let progress = MirsaOperationProgress.shared
        let hadHome = UserDefaults.standard.object(forKey: "mirsa.home.dockIDs")
        defer { if let hadHome { UserDefaults.standard.set(hadHome, forKey: "mirsa.home.dockIDs") } else { UserDefaults.standard.removeObject(forKey: "mirsa.home.dockIDs") } }
        let op = progress.begin(appID: app.id, phase: .downloading, cancel: {})
        defer { progress.finish(op) }
        XCTAssertEqual(progress.entry(for: app.id)?.canCancel, true)
        XCTAssertNil(progress.entry(for: app.id)?.fraction)
        try await snapshot(AppTile(app: app), name: "SIMULATOR-FIXTURE-main-AppTile-indeterminate-cancel")
        progress.update(op, phase: .downloading, fraction: 0.5)
        XCTAssertEqual(progress.entry(for: app.id)?.fraction, 0.5)
        XCTAssertEqual(progress.entry(for: app.id)?.canCancel, true)
        try await snapshot(AppTile(app: app), name: "SIMULATOR-FIXTURE-main-AppTile-50-percent-cancel")
        try await snapshot(MirsaHomeScreen(apps: [app], allAppIDs: [app.id], onLaunch: { _ in }, onSettings: {},
                                           onImport: {}, onDownloads: {}, menu: { _ in EmptyView() }),
                           name: "SIMULATOR-FIXTURE-main-home-50-percent")
        progress.cancel(op)
        XCTAssertNil(progress.entry(for: app.id))
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
