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

    func testProductionAnchorSetsInteractiveWithAccessoryOnScrollView() async throws {
        let window = UIWindow()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.addSubview(scroll)
        let anchor = MirsaKeyboardDismissal.KeyboardWindowAnchor()
        window.addSubview(anchor)
        anchor.applyExplicitDismissMode()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(scroll.keyboardDismissMode, .interactiveWithAccessory)
        XCTAssertEqual(scroll.keyboardDismissMode.rawValue, 4)
        anchor.removeFromSuperview()
    }

    // Real keyboard/CTA lifecycle coverage lives in MirsaKeyboardUITests.
    // Hosted XCTest has no AX client and may not own a foreground software keyboard.
}
