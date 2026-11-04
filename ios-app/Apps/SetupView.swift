import SwiftUI

/// Mirsa Setup: a small installer (meant to be signed with ESign/Feather) that
/// installs the real Mirsa with the user's Apple ID and hands over the login,
/// signing key and pairing so Mirsa works on first launch.
struct SetupView: View {
    @EnvironmentObject var vm: AppViewModel
    @StateObject private var store = AppsStore.shared
    @State private var showPairing = false
    @State private var showLogin = false

    private var networkOK: Bool { vm.vpnUp && vm.wifiUp }
    private var pairingOK: Bool { vm.hasPairingFile }
    private var accountOK: Bool { store.account != nil }
    private var ready: Bool { networkOK && pairingOK && accountOK }

    var body: some View {
        ZStack {
            AuroraBackground()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    step(1, icon: "lock.shield.fill", title: L.t("setup.network"),
                         status: networkOK ? L.t("setup.networkOK") : L.t("setup.networkOff"),
                         ok: networkOK, action: L.t("setup.check")) {
                        vm.refreshNetworkStatus()
                    }
                    step(2, icon: "link", title: L.t("setup.pairing"),
                         status: pairingOK ? L.t("setup.pairingOK") : L.t("setup.pairingOff"),
                         ok: pairingOK, action: L.t("setup.pairingOpen")) {
                        showPairing = true
                    }
                    step(3, icon: "apple.logo", title: L.t("setup.account"),
                         status: store.account?.email ?? L.t("setup.accountOff"),
                         ok: accountOK, action: accountOK ? nil : L.t("setup.signIn")) {
                        showLogin = true
                    }
                    installButton
                    if store.installedSelfBundleID != nil { doneCard }
                    Text(L.t("setup.note"))
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 10)
                }
                .padding(.horizontal, 20)
                .padding(.top, 30)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)

            if let busy = store.busy { BusyOverlay(text: busy, progress: store.progress) }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPairing, onDismiss: {
            vm.refreshPairingFile(); vm.refreshNetworkStatus()
        }) {
            SetupPairingSheet().environmentObject(vm)
                .presentationDetents([.large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showLogin) {
            LoginSheet(store: store)
                .presentationDetents([.large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $store.prompt) { p in
            PromptSheet(prompt: p) { store.prompt = nil }
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
                .interactiveDismissDisabled()
        }
        .alert(L.t("setup.title"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task {
            vm.refreshNetworkStatus()
            vm.refreshPairingFile()
            if store.account == nil && store.hasSavedLogin { await store.refreshAccount() }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Group {
                if let icon = UIImage(named: "AppIcon") {
                    Image(uiImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "sailboat.fill").font(.system(size: 40)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(red: 0.45, green: 0.38, blue: 1.0))
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            Text(L.t("setup.title")).font(.largeTitle.bold()).foregroundStyle(.white)
            Text(L.t("setup.sub"))
                .font(.subheadline).multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.bottom, 6)
    }

    private func step(_ n: Int, icon: String, title: String, status: String, ok: Bool,
                      action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(ok ? Color.green.opacity(0.85) : Color.white.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: ok ? "checkmark" : icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(n). \(title)").font(.headline).foregroundStyle(.white)
                Text(status).font(.subheadline)
                    .foregroundStyle(ok ? .green : .white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action: perform) {
                    Text(action).font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                }
                .foregroundStyle(.white)
                .appsGlassCapsule()
            }
        }
        .padding(16)
        .appsGlass(cornerRadius: 22)
    }

    private var installButton: some View {
        Button {
            Task { await store.installSelf(vm: vm) }
        } label: {
            Label(L.t("setup.install"), systemImage: "arrow.down.app.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(Color(red: 0.45, green: 0.38, blue: 1.0))
        .disabled(!ready || store.busy != nil)
        .padding(.top, 6)
    }

    private var doneCard: some View {
        VStack(spacing: 12) {
            Text(L.t("setup.installed"))
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            if let bid = store.installedSelfBundleID {
                Button(L.t("setup.open")) { _ = AppsStore.openInstalledApp(bundleID: bid) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.green)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .appsGlass(cornerRadius: 22, tint: .green)
    }
}
