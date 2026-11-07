import XCTest
import SwiftUI
@testable import Mirsa

@MainActor
final class MirsaKeyboardTests: XCTestCase {
    func testKeyboardVisibilityTracksRealNotificationLifecycle() {
        let center = NotificationCenter()
        let keyboard = MirsaKeyboardVisibility(center: center)
        XCTAssertFalse(keyboard.isVisible)
        center.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        XCTAssertTrue(keyboard.isVisible)
        // Keep CTA absent throughout interactive dismissal until keyboard is gone.
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        XCTAssertTrue(keyboard.isVisible)
        center.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertFalse(keyboard.isVisible)
    }

    func testEditingSelectionAndSecureFieldsAreExcluded() {
        let field = UITextField()
        field.isSecureTextEntry = true
        let caret = UIView()
        field.addSubview(caret)
        XCTAssertTrue(MirsaKeyboardDismissal.KeyboardWindowAnchor.isTextInteraction(caret))
        XCTAssertTrue(MirsaKeyboardDismissal.KeyboardWindowAnchor.isTextInteraction(UITextView()))
        XCTAssertFalse(MirsaKeyboardDismissal.KeyboardWindowAnchor.isTextInteraction(UIButton()))
        XCTAssertFalse(MirsaKeyboardDismissal.KeyboardWindowAnchor.isTextInteraction(UIView()))
    }

    func testWindowRecognizerDoesNotCancelControlsAndDetaches() throws {
        let window = UIWindow()
        let anchor = MirsaKeyboardDismissal.KeyboardWindowAnchor()
        window.addSubview(anchor)
        let tap = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first)
        XCTAssertFalse(tap.cancelsTouchesInView)
        XCTAssertFalse(tap.delaysTouchesBegan)
        XCTAssertFalse(tap.delaysTouchesEnded)
        XCTAssertFalse(anchor.isAccessibilityElement)
        anchor.removeFromSuperview()
        XCTAssertFalse(window.gestureRecognizers?.contains(tap) ?? false)
    }

    /// Actual project + actual first responder + OS keyboard notifications.
    /// Host simctl captures include the OS keyboard; a file handshake keeps this window alive.
    func testProjectActualKeyboardFocusedFieldAndCTA() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PersonalUIFixture", withExtension: "zip"))
        let library = PersonalAppsLibrary.shared
        let before = Set(library.apps.map(\.id))
        try await library.add(fixture, signed: false)
        let app = try XCTUnwrap(library.apps.first { !before.contains($0.id) })
        defer { try? library.delete(app) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: PersonalProjectDetailView(app: app)
            .mirsaKeyboardDismissal().environment(\.locale, Locale(identifier: "ar")))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; original?.makeKey() }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let fields = descendants(host.view).compactMap { $0 as? UITextField }
        let field = try XCTUnwrap(fields.first)
        XCTAssertTrue(accessibilityContains(window, identifier: "mirsa.project.sign"),
                      "CTA must exist before editing, otherwise this is not a valid restoration test")
        var keyboardFrame: CGRect?
        let token = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification,
            object: nil, queue: .main) { note in
                keyboardFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertTrue(field.becomeFirstResponder())
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(field.isFirstResponder)
        let frame = try XCTUnwrap(keyboardFrame, "Requires real software keyboard, not synthetic notification")
        let visibleField = field.convert(field.bounds, to: window)
        let keyboardTop = window.convert(frame, from: nil).minY
        XCTAssertLessThanOrEqual(visibleField.maxY, keyboardTop, "Focused project field remains above keyboard")
        XCTAssertGreaterThan(visibleField.height, 0)
        let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(scroll.keyboardDismissMode, UIScrollView.KeyboardDismissMode.interactiveWithAccessory)
        XCTAssertEqual(scroll.keyboardDismissMode.rawValue, 4, "interactiveWithAccessory raw value")
        XCTAssertFalse(accessibilityContains(window, identifier: "mirsa.project.sign"),
                       "CTA must not be exposed or cover the page while software keyboard is visible")
        try await attach("project-real-keyboard-visible-focused-field")
        window.endEditing(false)
        for _ in 0..<50 where accessibilityContains(window, identifier: "mirsa.project.sign") == false {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(field.isFirstResponder)
        try await attach("project-real-keyboard-hidden-CTA-restored")
        XCTAssertTrue(accessibilityContains(window, identifier: "mirsa.project.sign"),
                      "CTA must return after keyboard fully dismisses")
    }

    private func accessibilityContains(_ root: NSObject, identifier: String) -> Bool {
        var visited = Set<ObjectIdentifier>()
        func find(_ item: NSObject, depth: Int) -> Bool {
            guard depth < 60, visited.insert(ObjectIdentifier(item)).inserted else { return false }
            if let view = item as? UIView, view.accessibilityIdentifier == identifier { return true }
            if let element = item as? UIAccessibilityElement, element.accessibilityIdentifier == identifier { return true }
            if let view = item as? UIView {
                for child in view.subviews where find(child, depth: depth + 1) { return true }
            }
            for case let child as NSObject in item.accessibilityElements ?? [] {
                if find(child, depth: depth + 1) { return true }
            }
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for i in 0..<count {
                    if let child = item.accessibilityElement(at: i) as? NSObject,
                       find(child, depth: depth + 1) { return true }
                }
            }
            return false
        }
        return find(root, depth: 0)
    }

    private func attach(_ name: String) async throws {
        // Do not use NSLog as a trigger: xcodebuild buffers output for seconds,
        // so the screenshot may otherwise show an entirely different test.
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MirsaRuntimeCapture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let request = ["token": token, "name": name]
        try JSONSerialization.data(withJSONObject: request).write(
            to: directory.appendingPathComponent("request.json"), options: .atomic)
        for _ in 0..<400 {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("ack.json")),
               let ack = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               ack["token"] as? String == token {
                XCTAssertEqual(ack["ok"] as? Bool, true, "Host screenshot failed: \(ack)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for synchronous host screenshot \(name)")
    }
}
