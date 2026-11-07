import SwiftUI
import AirliftFFI

/// Entry point called from main.m once the Container loader has had its turn.
@_cdecl("mirsa_swift_main")
public func mirsaSwiftMain() {
    MirsaApp.main()
}

struct MirsaApp: App {
    @UIApplicationDelegateAdaptor(MirsaDownloadAppDelegate.self) private var downloadDelegate
    @StateObject private var vm = AppViewModel()
    @StateObject private var language = AppLanguageStore.shared

    init() {
        // Route Rust tracing/idevice logs into the app's vm log array.
        al_log_init({ _, msg in
            guard let msg = msg else { return }
            let line = String(cString: msg)
            DispatchQueue.main.async {
                AppViewModel.sharedLogSink?(line)
            }
        }, nil)

        // Point the sink at the vm once it's created (set in AppViewModel.init).
        // Ensure ALGetGrappaToken symbol is retained and linked into the binary
        _ = ALGetGrappaToken(0, 0, 0, nil, 0, nil, nil, 0)

        // Apps tab: background refresh of sideloaded apps must be registered
        // before launch finishes.
        AppsStore.registerBackgroundTask()
        AppsStore.importHandoffIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if AppsStore.isSetupMode { SetupView() } else { ContentView() }
            }
            .environmentObject(vm)
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.locale, language.current.locale)
            .id(language.current)
            .mirsaKeyboardDismissal()
        }
    }
}

@_silgen_name("ALGetGrappaToken")
func ALGetGrappaToken(
    _ inVersion: UInt32,
    _ inDeviceType: UInt32,
    _ inProtocolVersion: UInt32,
    _ outBuf: UnsafeMutablePointer<UInt8>?,
    _ maxLen: Int,
    _ outLen: UnsafeMutablePointer<Int>?,
    _ errBuf: UnsafeMutablePointer<CChar>?,
    _ errLen: Int
) -> Int32

