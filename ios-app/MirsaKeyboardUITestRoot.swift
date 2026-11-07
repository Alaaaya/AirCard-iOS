#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// A real foreground app scene for XCUITest, never compiled into device/release builds.
/// The runner supplies the offline fixture, so no test payload is shipped in the app.
struct MirsaKeyboardUITestRoot: View {
    @State private var app: PersonalLibraryApp?
    @State private var failure: String?

    var body: some View {
        Group {
            if let app { PersonalProjectDetailView(app: app) }
            else if let failure { Text(failure).accessibilityIdentifier("mirsa.fixture.failure") }
            else { ProgressView().accessibilityIdentifier("mirsa.fixture.loading") }
        }
        .task {
            guard app == nil else { return }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("keyboard-ui-fixture-\(UUID().uuidString).ipa")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                guard let encoded = ProcessInfo.processInfo.environment["MIRSA_KEYBOARD_FIXTURE"],
                      let data = Data(base64Encoded: encoded), data.count < 100_000 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try data.write(to: file, options: .atomic)
                let library = PersonalAppsLibrary.shared
                let before = Set(library.apps.map(\.id))
                try await library.add(file, signed: false)
                guard let imported = library.apps.first(where: { !before.contains($0.id) }) else {
                    throw CocoaError(.fileReadUnknown)
                }
                app = imported
            } catch { failure = String(describing: error) }
        }
        .onDisappear { if let app { try? PersonalAppsLibrary.shared.delete(app) } }
    }
}
#endif
