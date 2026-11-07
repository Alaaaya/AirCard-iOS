import SwiftUI
import UIKit

/// One non-cancelling recognizer per app window, including presented forms.
/// Never captures field contents or changes focus while editing/selecting text.
struct MirsaKeyboardDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardWindowAnchor { KeyboardWindowAnchor() }
    func updateUIView(_ uiView: KeyboardWindowAnchor, context: Context) {}

    final class KeyboardWindowAnchor: UIView, UIGestureRecognizerDelegate {
        private weak var attachedWindow: UIWindow?
        private lazy var outsideTap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            return tap
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard attachedWindow !== window else { return }
            attachedWindow?.removeGestureRecognizer(outsideTap)
            attachedWindow = window
            window?.addGestureRecognizer(outsideTap)
            applyExplicitDismissMode()
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        /// Raw value 4: interactive drag-to-dismiss, and any inputAccessoryView follows the
        /// keyboard. With no accessory it behaves exactly like .interactive (raw 2).
        /// SwiftUI's .interactively does not promise which UIKit mode it maps to, so set it.
        func applyExplicitDismissMode() {
            DispatchQueue.main.async { [weak self] in
                guard let root = self?.window else { return }
                func walk(_ v: UIView) {
                    if let s = v as? UIScrollView { s.keyboardDismissMode = .interactiveWithAccessory }
                    v.subviews.forEach(walk)
                }
                walk(root)
            }
        }

        override func layoutSubviews() { super.layoutSubviews(); applyExplicitDismissMode() }

        @objc private func dismissKeyboard() {
            attachedWindow?.endEditing(false)
        }

        static func isTextInteraction(_ view: UIView?) -> Bool {
            var current = view
            while let item = current {
                // Includes UITextField (also SecureField), UITextView, and their
                // selection/caret subviews. Tapping another field must focus it.
                if item is UITextField || item is UITextView { return true }
                if item is UIControl && item.canBecomeFirstResponder { return true }
                current = item.superview
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !Self.isTextInteraction(touch.view)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Uses keyboard events rather than ignoring keyboard safe areas, so SwiftUI
/// continues scrolling the focused input above the software keyboard.
final class MirsaKeyboardVisibility: ObservableObject {
    @Published private(set) var isVisible = false
    private var tokens: [NSObjectProtocol] = []
    private var hideGeneration = 0

    init(center: NotificationCenter = .default) {
        self.center = center
        tokens = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hideGeneration += 1
                self?.isVisible = true
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] note in
                // DidHide can be late or skipped when the hosting window/sheet changes
                // during dismissal; restore after the hide animation if no Show intervened.
                guard let self else { return }
                self.hideGeneration += 1
                let generation = self.hideGeneration
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.35
                DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.15) { [weak self] in
                    guard let self, self.hideGeneration == generation else { return }
                    self.isVisible = false
                }
            },
            center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hideGeneration += 1
                self?.isVisible = false
            }
        ]
    }
    private let center: NotificationCenter
    deinit { tokens.forEach { center.removeObserver($0) } }
}

extension View {
    /// Inherited by descendant ScrollViews, Lists and Forms, including sheets.
    func mirsaKeyboardDismissal() -> some View {
        scrollDismissesKeyboard(.interactively)
            .background(MirsaKeyboardDismissal().frame(width: 0, height: 0))
    }
}
