import XCTest

/// Uses the OS accessibility server and a real foreground application scene.
/// No synthetic keyboard events, private API, or best-effort AX tree traversal.
final class MirsaKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "PersonalUIFixture", withExtension: "zip"))
        app = XCUIApplication()
        app.launchArguments = ["--mirsa-keyboard-ui-test", "-AppleLanguages", "(ar,en)", "-AppleLocale", "ar"]
        app.launchEnvironment["MIRSA_KEYBOARD_FIXTURE"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    }

    override func tearDownWithError() throws {
        if let app {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "project-keyboard-final-state"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
        app = nil
    }

    func testProjectActualKeyboardFocusedFieldAndCTA() throws {
        let cta = app.buttons["mirsa.project.sign"]
        XCTAssertTrue(cta.waitForExistence(timeout: 20),
                      "CTA must exist before editing; restoration cannot pass vacuously")
        XCTAssertTrue(cta.isHittable)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "Requires the actual software keyboard")
        XCTAssertTrue(field.isHittable)
        XCTAssertGreaterThan(field.frame.height, 0)
        XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY,
                                 "Focused project field must remain above the software keyboard")
        XCTAssertTrue(waitUntil { !cta.exists }, "CTA must disappear while keyboard is visible")
        attach("project-real-keyboard-visible-focused-field")
        let title = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@",
            "تفاصيل المشروع", "Project details")).firstMatch
        XCTAssertTrue(title.exists)
        title.tap() // Real outside tap exercises the production non-cancelling recognizer.
        XCTAssertTrue(waitUntil { !keyboard.exists }, "Outside tap must dismiss the real keyboard")
        // Capture even if CTA restoration is broken, then assert its actual OS AX state.
        _ = waitUntil { cta.exists && cta.isHittable }
        attach("project-real-keyboard-hidden-CTA-restored")
        XCTAssertTrue(cta.exists, "CTA must return after the keyboard fully dismisses")
        XCTAssertTrue(cta.isHittable)
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 8) == .completed
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
