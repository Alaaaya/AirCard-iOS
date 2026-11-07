import AppIntents
import UserNotifications

/// "Renew Apps" — for a Shortcuts personal automation (e.g. daily, or when
/// joining home Wi-Fi) so sideloaded real apps never hit their 7-day expiry.
/// Needs the loopback VPN and a valid pairing record, the same as refreshing from the Apps tab.
struct RefreshAppsIntent: AppIntent {
    static var title: LocalizedStringResource = "Renew Mirsa Apps"
    static var description = IntentDescription("Re-signs and reinstalls every app Mirsa installed as a real app, and re-signs Container apps when the certificate changed.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Only when expiring within (days, 0 = all)", default: 2) var withinDays: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppsStore.shared
        guard await store.ensureSession() else {
            return .result(dialog: IntentDialog(stringLiteral: L.t("err.notSignedIn")))
        }
        await store.refreshAccount()
        let n = await store.refreshAll(vm: AppViewModel.shared, withinDays: withinDays > 0 ? withinDays : nil)
        if let e = store.error, n == 0, !store.realApps.isEmpty {
            store.error = nil
            return .result(dialog: IntentDialog(stringLiteral: e))
        }
        return .result(dialog: IntentDialog(stringLiteral: L.f("toast.refreshed", n)))
    }
}

struct MirsaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAppsIntent(),
            phrases: [
                "Renew apps in \(.applicationName)",
                "Renew \(.applicationName) apps",
            ],
            shortTitle: "Renew Apps",
            systemImageName: "arrow.clockwise.circle"
        )
        AppShortcut(intent: RefreshAllAppsIntent(),
                    phrases: ["Renew all apps with \(.applicationName)"],
                    shortTitle: "Renew All Apps", systemImageName: "arrow.clockwise")
        AppShortcut(intent: OpenAppInMirsaIntent(),
                    phrases: ["Open an app in \(.applicationName)"],
                    shortTitle: "Open App in Mirsa", systemImageName: "app")
        AppShortcut(
            intent: InstallFromLinkIntent(),
            phrases: ["Install IPA with \(.applicationName)"],
            shortTitle: "Install from Link",
            systemImageName: "arrow.down.app"
        )
    }
}

struct RefreshAllAppsIntent: AppIntent {
    static var title: LocalizedStringResource = "Renew All Apps"
    static var description = IntentDescription("Renew all installed apps. Connect LocalDevVPN first.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let store = AppsStore.shared
        let vm = AppViewModel.shared ?? AppViewModel()
        vm.refreshNetworkStatus()
        var succeeded = false
        var message = tr("Enable LocalDevVPN and check your pairing file.", "فعّل LocalDevVPN وتأكد من صحة ملف الاقتران.")
        if vm.vpnUp {
            if store.busy != nil {
                message = tr("Mirsa is busy. Try again later.", "Mirsa مشغول. جرّب بعد شوي.")
            } else if await store.ensureSession() {
                store.error = nil
                await store.refreshAccount()
                let expected = store.realApps.count
                let count = await store.refreshAll(vm: vm, withinDays: nil)
                for app in store.apps where app.location == .container {
                    await store.resign(app)
                    if store.error != nil { break }
                }
                succeeded = count == expected && store.error == nil
                message = succeeded ? tr("All apps renewed.", "تجدّدت كل التطبيقات.") :
                    (store.error ?? tr("Some apps could not be renewed.", "ما قدر يجدّد كل التطبيقات."))
            } else {
                message = tr("Sign in to Mirsa first.", "سجّل دخولك بـMirsa أولاً.")
            }
        }
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = "Mirsa"; content.body = message; content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "mirsa.refresh-all", content: content, trigger: nil))
        return .result(value: succeeded, dialog: IntentDialog(stringLiteral: message))
    }
}

struct OpenAppInMirsaIntent: AppIntent {
    static var title: LocalizedStringResource = "Open App in Mirsa"
    static var openAppWhenRun = true
    @Parameter(title: "App ID") var appID: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let app = AppsStore.shared.apps.first(where: { $0.id == appID }) else {
            return .result(dialog: IntentDialog(stringLiteral: tr("App not found in Mirsa.", "التطبيق مو موجود بـMirsa.")))
        }
        AppsStore.shared.launch(app)
        return .result(dialog: IntentDialog(stringLiteral: app.name))
    }
}
