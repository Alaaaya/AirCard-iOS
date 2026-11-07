import XCTest
import Vision
import SwiftUI
@testable import Mirsa

private final class SnapshotSecrets: HiddenSecretStore {
    var d: [String: Data] = [:]
    func read(_ a: String) -> HiddenSecretRead { d[a].map { .found($0) } ?? .missing }
    func write(_ a: String, _ x: Data) -> Bool { d[a] = x; return true }
}

@MainActor
final class PersonalProjectIntegrationTests: XCTestCase {
    /// Production HiddenAppsStore fails closed when the unsigned simulator keychain errors, which blanked every list screenshot.
    /// Snapshots use an isolated in-memory store; the assertion proves rows really are visible.
    private func isolatedStore() -> HiddenAppsStore {
        let store = HiddenAppsStore(secrets: SnapshotSecrets())
        XCTAssertEqual(store.health, .ok)
        return store
    }

    func testOwnProjectFolderMigrationAndCertificateNameSnapshots() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PersonalUIFixture", withExtension: "zip"))
        let library = PersonalAppsLibrary.shared
        let before = Set(library.apps.map(\.id))
        try await library.add(fixture, signed: false)
        let app = try XCTUnwrap(library.apps.first { !before.contains($0.id) })
        var folder: URL?
        defer {
            try? library.delete(app)
            if let folder { try? FileManager.default.removeItem(at: folder) }
        }
        let oldIPA = library.url(app)
        let oldIcon = library.iconURL(app)
        var draft = PersonalProjectDraft(name: app.name, bundleID: app.bundleID, version: app.version)
        draft.workspaceNote = "migration fixture"
        try JSONEncoder().encode(draft).write(to: library.draftURL(app))
        let originalDraft = try Data(contentsOf: library.draftURL(app))
        folder = try library.browseDirectory(app)
        let root = try XCTUnwrap(folder)
        XCTAssertEqual(root.lastPathComponent, app.id.uuidString)
        XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, "Projects")
        XCTAssertEqual(library.url(app).deletingLastPathComponent(), root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldIPA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldIcon.path))
        XCTAssertEqual(try Data(contentsOf: library.draftURL(app)), originalDraft)
        XCTAssertNotNil(library.icon(for: app))
        XCTAssertEqual(try library.browseDirectory(app), root)
        XCTAssertEqual(try PersonalProjectFolder.contents(of: root, in: root).count, 3)
        try await snapshot(PersonalProjectFolderBrowser(root: root, title: app.name), name: "Arabic-Mirsa-own-project-folder-no-Files-redirect")
        let certURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "escaped", withExtension: "der", subdirectory: "CertificateLabels")
            ?? Bundle(for: Self.self).url(forResource: "escaped", withExtension: "der"))
        let name = PersonalCertificateLabel.name(certificate: try Data(contentsOf: certURL))
        XCTAssertEqual(name, "فريق Mirsa, Example")
        try await snapshot(VStack(alignment: .leading) {
            Label("شهادة التوقيع", systemImage: "key.fill")
            Text(name).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }.padding().background(AuroraBackground()), name: "Arabic-certificate-structured-CN-not-raw-DN")
    }

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
        let restoreDefaults = preserveDefaults(Self.layoutKeys + ["mirsa.personal.projects.grid"])
        defer { restoreDefaults() }
        let before = Set(library.apps.map(\.id))
        try await library.add(fixture, signed: false)
        let app = try XCTUnwrap(library.apps.first { !before.contains($0.id) })
        defer { try? library.delete(app) }
        let icon = try XCTUnwrap(library.icon(for: app), "The real fixture IPA icon must be extracted, not a placeholder")
        XCTAssertEqual(icon.size.width, 180)
        XCTAssertEqual(icon.size.height, 180)
        // Realistic multi-app list: three imports of the real fixture IPA, removed in defer.
        var extra: [PersonalLibraryApp] = []
        defer { for a in extra { try? library.delete(a) } }
        for _ in 0..<2 {
            let known = Set(library.apps.map(\.id))
            try await library.add(fixture, signed: false)
            if let a = library.apps.first(where: { !known.contains($0.id) }) { extra.append(a) }
        }
        XCTAssertEqual(extra.count, 2)
        let store = isolatedStore()
        XCTAssertEqual(store.visible(library.apps, ns: .personal, id: { $0.id.uuidString }).count, library.apps.count, "populated rows must be visible")
        XCTAssertGreaterThanOrEqual(library.apps.count, 3)
        try await snapshot(PersonalAppsHub(hiddenStore: store), name: "Arabic-projects-real-SwiftUI-multi-fixture")
        // Real phone-size top and bottom scroll captures show the last settings row and sticky sign button.
        try await snapshot(PersonalProjectDetailView(app: app), name: "Arabic-project-details-top-430x932")
        try await snapshot(PersonalProjectDetailView(app: app), name: "Arabic-project-details-bottom-430x932-last-row-and-sign-button", scrollToBottom: true)
        try await snapshot(NavigationStack { ScrollView { PersonalCertificateView().padding(20) }.background(AuroraBackground()) }, name: "Arabic-certificate-import-real-SwiftUI")
        try await snapshot(PersonalProjectDetailView(app: app), name: "Arabic-project-details-real-SwiftUI-fixture")
    }

    func testTweakChipSnapshotHomeToggleAndHiddenUI() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PersonalUIFixture", withExtension: "zip"))
        let library = PersonalAppsLibrary.shared
        let tweaks = IPATweakLibrary.shared
        let defaults = UserDefaults.standard
        let gridKey = "mirsa.personal.projects.grid"
        let restoreDefaults = preserveDefaults(Self.layoutKeys + [gridKey])
        let beforeApps = Set(library.apps.map(\.id)), beforeTweaks = Set(tweaks.items.map(\.id))
        // Harmless synthetic bytes named like a dylib; imported as data, never loaded or executed.
        let dylib = FileManager.default.temporaryDirectory.appendingPathComponent("testdylib-\(UUID().uuidString).dylib")
        try Data("not executable fixture".utf8).write(to: dylib)
        defer {
            try? FileManager.default.removeItem(at: dylib)
            for t in tweaks.items where !beforeTweaks.contains(t.id) { try? tweaks.delete(t) }
            for a in library.apps where !beforeApps.contains(a.id) { try? library.delete(a) }
            restoreDefaults()
        }
        try await library.add(fixture, signed: false)
        let app = try XCTUnwrap(library.apps.first { !beforeApps.contains($0.id) })
        try await tweaks.addFile(dylib)
        let tweak = try XCTUnwrap(tweaks.items.first { !beforeTweaks.contains($0.id) }, "Tweak import must create a real library item; no chip proof without it")
        XCTAssertEqual(tweak.roots, [dylib.lastPathComponent])
        let store = isolatedStore()
        XCTAssertFalse(store.visible(library.apps, ns: .personal, id: { $0.id.uuidString }).isEmpty)
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
        try await snapshot(PersonalAppsHub(hiddenStore: store), name: "Personal-ring-indeterminate-fixture")
        progress.update(op, phase: .signing, fraction: 0.5)
        try await snapshot(PersonalAppsHub(hiddenStore: store), name: "Personal-ring-determinate-fixture")
        let mainOp = progress.begin(appID: "com.example.main", phase: .downloading, cancel: {})
        defer { progress.finish(mainOp) }
        XCTAssertEqual(progress.entry(for: "com.example.main")?.canCancel, true)
        progress.cancel(mainOp)
        XCTAssertNil(progress.entry(for: "com.example.main"), "cancel must clear a cancellable operation")
        defaults.set(false, forKey: gridKey)
        try await snapshot(PersonalAppsHub(hiddenStore: store), name: "Personal-list-default-tweak-chip-x")
        defaults.set(true, forKey: gridKey)
        try await snapshot(PersonalAppsHub(hiddenStore: store), name: "Personal-home-toggle-grid")
        try await snapshot(HiddenAppsView(store: store) { PersonalHiddenGrid(apps: library.apps, pendingHide: .constant(nil), hidden: store) }, name: "Arabic-hidden-apps-PIN-UI")
    }

    /// SIMULATOR FIXTURE: seeded real MirsaOperationProgress state rendered by the real AppTile/MirsaHomeScreen.
    /// Not a network download and not a device run.
    func testSimulatorFixtureMainTileRing() async throws {
        let app = ManagedApp(id: "com.example.ringfixture", name: "Ring Fixture", version: "1.0", sizeBytes: 1,
                             location: .container, installedBundleID: nil, expires: nil, signedSerial: nil,
                             wantsNotifications: false, hasExtensions: false, addedAt: Date())
        let restoreDefaults = preserveDefaults(Self.layoutKeys)
        defer { restoreDefaults() }
        let progress = MirsaOperationProgress.shared
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

    /// Real populated folder that keeps a hidden member id; rendered through the real MirsaFolderOverlay.
    func testPopulatedFolderPreservesHiddenMembership() async throws {
        let ids = ["com.example.a", "com.example.b", "com.example.c"]
        let apps = ids.enumerated().map { i, id in
            ManagedApp(id: id, name: "Folder App \(i + 1)", version: "1.0", sizeBytes: 1, location: .container, installedBundleID: nil,
                       expires: nil, signedSerial: nil, wantsNotifications: false, hasExtensions: false, addedAt: Date())
        }
        let suite = "mirsa.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = MirsaHomeLayoutStore(namespace: "snap", defaults: defaults)
        layout.mutate { $0.items = [.folder(MirsaHomeFolder(id: "f1", name: "مجلد", appIDs: ids + ["com.example.hidden"]))] }
        XCTAssertEqual(layout.layout.folder("f1")?.appIDs.count, 4, "hidden member must stay in the folder model")
        let shown = Set(ids)
        try await snapshot(MirsaFolderOverlay(store: layout, folderID: "f1", visible: shown, onClose: {},
                                              tile: { id in Text(apps.first { $0.id == id }?.name ?? id).padding() }),
                           name: "Arabic-folder-populated-hidden-member-preserved")
        XCTAssertEqual(layout.layout.folder("f1")?.appIDs.count, 4)
    }


    /// Offline simulator fixture, validated through the same IPA verifier as real sources.
    /// This does not claim a live host download or a device run.
    func testDiscoveryValidatedIPAAndEmptyArabicSnapshots() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PersonalUIFixture", withExtension: "zip"))
        let facts = try IPAValidator.validate(file: fixture, expectedBundleID: nil, expectedVersion: nil, deviceOS: nil)
        let raw = DiscoveryCandidate(name: facts.displayName, bundleID: facts.bundleID,
            developer: "Local test fixture", version: facts.version, minOS: facts.minOS, iconURL: nil,
            downloadURL: URL(string: "https://downloads.example.org/fixture.ipa"),
            sourceName: "Offline IPA fixture", sourceURL: "https://downloads.example.org/source.json",
            origin: .userSource, identity: .nameOnly)
        let valid = try XCTUnwrap(DiscoveryIPAVerifier.validated(raw, file: fixture,
            expectedBundleID: facts.bundleID, queryName: facts.displayName))
        XCTAssertEqual(valid.identity, .bundleVerified)
        XCTAssertTrue(valid.isDownloadable)
        let reference = DiscoveryCandidate(name: "FORBIDDEN-REFERENCE-x.com", bundleID: "invalid.reference",
            developer: "", version: "", minOS: nil, iconURL: nil,
            downloadURL: URL(string: "https://x.com/reference.ipa"), sourceName: "FORBIDDEN-REFERENCE",
            sourceURL: "https://x.com", origin: .appleMetadata, identity: .reference)
        let store = DiscoveryStore()
        store.input = facts.displayName
        store.outcome = DiscoveryOutcome(query: .name(facts.displayName), candidates: [valid, reference],
            reports: [], ambiguous: false, note: nil)
        try await snapshot(DiscoveryView(store: store), name: "Arabic-Discovery-real-validated-IPA-offline-fixture",
            requiredText: [facts.displayName, facts.bundleID, "تنزيل", "لا"],
            forbiddenText: ["FORBIDDEN-REFERENCE", "x.com", "References", "مراجع"])
        store.dismiss(valid)
        XCTAssertEqual(store.states[valid.id], .dismissed)
        store.outcome = DiscoveryOutcome(query: .name("Absent app"), candidates: [reference],
            reports: [], ambiguous: false, note: DiscoveryEngine.emptyMessage)
        try await snapshot(DiscoveryView(store: store), name: "Arabic-Discovery-empty-no-references",
            requiredText: [DiscoveryEngine.emptyMessage],
            forbiddenText: ["FORBIDDEN-REFERENCE", "x.com", "References", "مراجع", "تنزيل"])
    }

    /// SwiftUI exposes virtual accessibility containers, not UILabel subviews.
    /// Walk the public container API as well as UIKit children; never accept an empty tree.
    private func renderedAccessibilityText(_ view: UIView) -> String {
        var visited = Set<ObjectIdentifier>()
        var pieces: [String] = []
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 64, visited.count < 10_000,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let text = object.accessibilityLabel { pieces.append(text) }
            if let text = object.accessibilityValue { pieces.append(text) }
            if let label = object as? UILabel, let text = label.text { pieces.append(text) }
            if let button = object as? UIButton, let text = button.title(for: .normal) { pieces.append(text) }
            if let childView = object as? UIView {
                for child in childView.subviews { visit(child, depth: depth + 1) }
            }
            if let elements = object.accessibilityElements {
                for case let child as NSObject in elements { visit(child, depth: depth + 1) }
            }
            let count = object.accessibilityElementCount()
            if count > 0 && count <= 1_000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject {
                        visit(child, depth: depth + 1)
                    }
                }
            }
        }
        visit(view, depth: 0)
        return pieces.joined(separator: "\n")
    }

    private static let layoutKeys = ["mirsa.home.layout.v1.main", "mirsa.home.layout.v1.personal", "mirsa.home.orderIDs",
                                     "mirsa.home.dockIDs", "mirsa.home.wallpaper"]
    /// Snapshots each key now; the returned closure restores the value or removes the key if it was absent.
    private func preserveDefaults(_ keys: [String]) -> () -> Void {
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        return { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
    }

    private func findScrollView(_ v: UIView) -> UIScrollView? {
        if let s = v as? UIScrollView, s.contentSize.height > 0 { return s }
        for sub in v.subviews { if let s = findScrollView(sub) { return s } }
        return nil
    }

    private func snapshot<V: View>(_ view: V, name: String, height: CGFloat = 932, scrollToBottom: Bool = false, requiredText: [String] = [], forbiddenText: [String] = []) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: height)
        let host = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "ar")).environment(\.layoutDirection, .leftToRight))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; original?.makeKey() }
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 800_000_000)
        host.view.layoutIfNeeded()
        if scrollToBottom {
            let scroll = try XCTUnwrap(findScrollView(host.view), "A UIScrollView must exist in the hosted view")
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height, "Content must overflow the 430x932 viewport")
            let y = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 500_000_000)
            host.view.layoutIfNeeded()
            XCTAssertEqual(scroll.contentOffset.y, y, accuracy: 1, "Scroll view must really be at the bottom")
        }
        if !requiredText.isEmpty || !forbiddenText.isEmpty {
            // SwiftUI exposes its accessibility tree lazily; poll (bounded) until required text appears.
            var text = renderedAccessibilityText(host.view)
            var tries = 0
            while tries < 30, !requiredText.allSatisfy({ text.contains($0) }) {
                try await Task.sleep(nanoseconds: 200_000_000)
                window.layoutIfNeeded(); host.view.layoutIfNeeded()
                text = renderedAccessibilityText(host.view)
                tries += 1
            }
            // NavigationStack content is not exposed through the hosted accessibility tree on the simulator
            // (only the bar title is). Fall back to OCR of the actually drawn pixels; assertions stay unchanged.
            if !requiredText.allSatisfy({ text.contains($0) }) {
                let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 2
                let shot = UIGraphicsImageRenderer(size: window.bounds.size, format: fmt).image { _ in
                    _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                if let cg = shot.cgImage {
                    let req = VNRecognizeTextRequest()
                    req.recognitionLevel = .accurate
                    req.usesLanguageCorrection = false
                    if #available(iOS 18.0, *) { req.automaticallyDetectsLanguage = true }
                    try? VNImageRequestHandler(cgImage: cg).perform([req])
                    let ocr = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    text += "\n" + ocr
                }
            }
            XCTAssertFalse(text.isEmpty, "Hosted SwiftUI accessibility tree must not be empty")
            for expected in requiredText { XCTAssertTrue(text.contains(expected), "Missing rendered text: \(expected); actual: \(text)") }
            for forbidden in forbiddenText { XCTAssertFalse(text.contains(forbidden), "Forbidden rendered text: \(forbidden)") }
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var rendered = false
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered)
        XCTAssertEqual(image.size, CGSize(width: 430, height: height))
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
