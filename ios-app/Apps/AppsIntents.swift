import AppIntents

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
        AppShortcut(
            intent: InstallFromLinkIntent(),
            phrases: ["Install IPA with \(.applicationName)"],
            shortTitle: "Install from Link",
            systemImageName: "arrow.down.app"
        )
    }
}
