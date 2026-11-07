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
    /// Attachments use XCUIScreen so the software keyboard is included.
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
        attach("project-real-keyboard-visible-focused-field")
        window.endEditing(false)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(field.isFirstResponder)
        attach("project-real-keyboard-hidden-CTA-restored")
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
