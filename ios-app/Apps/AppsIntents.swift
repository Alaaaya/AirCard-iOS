import AppIntents
import UserNotifications

/// "Refresh Apps" — for a Shortcuts personal automation (e.g. daily, or when
/// joining home Wi-Fi) so sideloaded real apps never hit their 7-day expiry.
/// Needs Wi-Fi + the loopback VPN, the same as refreshing from the Apps tab.
struct RefreshAppsIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Mirsa Apps"
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

struct AirCardAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAppsIntent(),
            phrases: [
                "Refresh apps in \(.applicationName)",
                "Refresh \(.applicationName) apps",
            ],
            shortTitle: "Refresh Apps",
            systemImageName: "arrow.clockwise.circle"
        )
        AppShortcut(intent: RefreshAllAppsIntent(),
                    phrases: ["Refresh all apps with \(.applicationName)"],
                    shortTitle: "Refresh All Apps", systemImageName: "arrow.clockwise")
        AppShortcut(intent: OpenAppInMirsaIntent(),
                    phrases: ["Open an app in \(.applicationName)"],
                    shortTitle: "Open App in Mirsa", systemImageName: "app")
        AppShortcut(intent: OpenSavedMirsaAppIntent(),
                    phrases: ["Open a saved app with \(.applicationName)",
                              "Open \(\.$app) with \(.applicationName)"],
                    shortTitle: "Open Saved App", systemImageName: "app.badge.checkmark")
        AppShortcut(
            intent: InstallFromLinkIntent(),
            phrases: ["Install IPA with \(.applicationName)"],
            shortTitle: "Install from Link",
            systemImageName: "arrow.down.app"
        )
    }
}

struct RefreshAllAppsIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh All Apps"
    static var description = IntentDescription("Refresh all installed apps. Connect LocalDevVPN first.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let store = AppsStore.shared
        let vm = AppViewModel.shared ?? AppViewModel()
        vm.refreshNetworkStatus()
        var succeeded = false
        var message = tr("Connect LocalDevVPN and Wi-Fi first.", "شغّل LocalDevVPN والواي فاي أولاً.")
        if vm.vpnUp && vm.wifiUp {
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
                message = succeeded ? tr("All apps refreshed.", "تجدّدت كل التطبيقات.") :
                    (store.error ?? tr("Some apps could not be refreshed.", "ما قدر يجدّد كل التطبيقات."))
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

/// The entity is serialized into each shortcut. Changing the current suggestion
/// must never redirect icons that the user already added for another app.
struct MirsaShortcutApp: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mirsa App"
    static var defaultQuery = MirsaShortcutAppQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MirsaShortcutAppQuery: EntityStringQuery {
    static let preferredAppKey = "mirsa.shortcut.preferredAppID"

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MirsaShortcutApp] {
        identifiers.compactMap { id in
            AppsStore.shared.apps.first(where: { $0.id == id })
                .map { MirsaShortcutApp(id: $0.id, name: $0.name) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [MirsaShortcutApp] {
        let preferred = UserDefaults.standard.string(forKey: Self.preferredAppKey)
        let apps = AppsStore.shared.apps.sorted {
            if $0.id == preferred { return $1.id != preferred }
            if $1.id == preferred { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return apps.map { MirsaShortcutApp(id: $0.id, name: $0.name) }
    }

    @MainActor
    func defaultResult() async -> MirsaShortcutApp? {
        guard let id = UserDefaults.standard.string(forKey: Self.preferredAppKey),
              let app = AppsStore.shared.apps.first(where: { $0.id == id }) else { return nil }
        return MirsaShortcutApp(id: app.id, name: app.name)
    }

    @MainActor
    func entities(matching string: String) async throws -> [MirsaShortcutApp] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

struct OpenSavedMirsaAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Saved App"
    static var description = IntentDescription("Open an installed Mirsa app. Choose the app by name, then add this shortcut to your Home Screen.")
    static var openAppWhenRun = true
    @Parameter(title: "App") var app: MirsaShortcutApp

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$app) in Mirsa")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let installed = AppsStore.shared.apps.first(where: { $0.id == app.id }) else {
            return .result(dialog: IntentDialog(stringLiteral: tr("App not found in Mirsa.", "التطبيق مو موجود بـMirsa.")))
        }
        AppsStore.shared.launch(installed)
        return .result(dialog: IntentDialog(stringLiteral: installed.name))
    }
}
