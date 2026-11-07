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

    private static var hostedUnitTests: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        #else
        return false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // Hosted XCTest windows own their fixtures. Do not let the ordinary
                // home start network work or present OS permission sheets behind them.
                if Self.hostedUnitTests { Color.clear }
                else if AppsStore.isSetupMode { SetupView() } else { ContentView() }
            }
            .environmentObject(vm)
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

