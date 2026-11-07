import XCTest
import SwiftUI
@testable import Mirsa

@MainActor
final class IncomingIPAExplicitTests: XCTestCase {
    func testExplicitCallbacksAreIndependentAndPresentationDoesNotAct() {
        var calls = [String]()
        let url = URL(fileURLWithPath: "/fixture.ipa")
        let view = IncomingIPAConfirmationSheet(url: url, filename: "fixture.ipa",
            onCancel: { calls.append("cancel") }, onImportProject: { _ in calls.append("project") },
            onAppleID: { _ in calls.append("apple") }, onSaveLibrary: { _ in calls.append("library") },
            onSignInstall: { _, _ in calls.append("certificate") })
        XCTAssertTrue(calls.isEmpty)
        view.onAppleID?(url)
        XCTAssertEqual(calls, ["apple"])
        view.onSaveLibrary?(url)
        XCTAssertEqual(calls, ["apple", "library"])
        view.onImportProject(url)
        XCTAssertEqual(calls, ["apple", "library", "project"])
        view.onCancel()
        XCTAssertEqual(calls.last, "cancel")
    }

    func testRealConfirmationSheetSnapshots() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PersonalUIFixture", withExtension: "zip"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Fixture.ipa")
        try FileManager.default.copyItem(at: fixture, to: url)
        let old = AppLanguageStore.shared.current
        defer { AppLanguageStore.shared.set(old) }
        for language in [AppLanguage.arabic, .english] {
            AppLanguageStore.shared.set(language)
            let view = IncomingIPAConfirmationSheet(url: url, filename: "Fixture.ipa", onCancel: {},
                onImportProject: { _ in }, onAppleID: { _ in }, onSaveLibrary: { _ in }, onSignInstall: { _, _ in })
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let original = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
            let host = UIHostingController(rootView: view)
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds; window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Mirsa128-explicit-openin-\(language.rawValue)"
            attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true; original?.makeKey()
        }
    }
}
