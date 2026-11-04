import SwiftUI
import UniformTypeIdentifiers

/// Mirsa Setup's own pairing screen: network, pair on this iPhone, or import.
struct SetupPairingSheet: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false
    var showsClose = true

    private var networkOK: Bool { vm.vpnUp && vm.wifiUp }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        Text(L.t("setup.pairing")).font(.largeTitle.bold()).foregroundStyle(.white)
                        Spacer()
                        if showsClose { Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                        }
                        .appsGlassCapsule() }
                    }
                    .padding(.bottom, 4)

                    networkCard
                    statusCard
                    pairCard
                    importCard
                }
                .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 50)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView(allowedContentTypes: [
                UTType(filenameExtension: "mobiledevicepairing") ?? .data,
                UTType(filenameExtension: "mobilepair") ?? .data,
                .propertyList, .data, .item
            ]) { url in
                _ = vm.importPairingFile(from: url, originalName: url.lastPathComponent)
                vm.refreshPairingFile()
            }
        }
        .task { vm.refreshNetworkStatus(); vm.refreshPairingFile() }
    }

    private func row(icon: String, ok: Bool, title: String, sub: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(ok ? Color.green.opacity(0.85) : Color.orange.opacity(0.8)).frame(width: 40, height: 40)
                Image(systemName: ok ? "checkmark" : icon).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(sub).font(.subheadline).foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 0)
        }
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(icon: "lock.shield", ok: networkOK, title: L.t("setup.network"),
                sub: networkOK ? L.t("setup.networkOK") : L.t("setup.networkOff"))
            HStack(spacing: 10) {
                if !networkOK {
                    Button {
                        if let u = URL(string: "localdevvpn://") { UIApplication.shared.open(u) }
                    } label: {
                        Label(L.t("pair.openVPN"), systemImage: "arrow.up.forward.app")
                            .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .foregroundStyle(.white).appsGlassCapsule(tint: .orange)
                }
                Spacer()
                Button { vm.refreshNetworkStatus() } label: {
                    Image(systemName: "arrow.clockwise").font(.subheadline.weight(.bold))
                        .foregroundStyle(.white).frame(width: 36, height: 36)
                }
                .appsGlassCapsule()
            }
        }
        .padding(16).appsGlass(cornerRadius: 22)
    }

    private var statusCard: some View {
        row(icon: "link", ok: vm.hasPairingFile, title: L.t("setup.pairing"),
            sub: vm.hasPairingFile ? L.t("setup.pairingOK") : L.t("setup.pairingOff"))
            .padding(16).appsGlass(cornerRadius: 22)
    }

    private var pairCard: some View {
        VStack(spacing: 14) {
            if vm.pairingPhase == .pairing {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(vm.pairingStatus.isEmpty ? L.t("pair.starting") : vm.pairingStatus)
                        .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    Spacer()
                }
                if let pin = vm.pairingPIN {
                    Text(L.t("pair.enterPIN")).font(.caption.bold()).foregroundStyle(.white.opacity(0.6))
                    HStack {
                        Text(pin).font(.system(size: 40, weight: .black, design: .monospaced)).foregroundStyle(.orange)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = pin
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        } label: { Image(systemName: "doc.on.doc").foregroundStyle(.white).frame(width: 40, height: 40) }
                        .appsGlassCapsule(tint: .orange)
                    }
                    Text(L.t("pair.where")).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    } label: {
                        Text(L.t("pair.openSettings")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.orange)
                }
                Button(L.t("choice.cancel")) { vm.cancelPairing() }
                    .foregroundStyle(.red)
            } else {
                if !vm.pairingStatus.isEmpty && vm.pairingStatus != "idle" {
                    Text(vm.pairingStatus).font(.subheadline).multilineTextAlignment(.center)
                        .foregroundStyle(vm.pairingStatus.contains("✅") ? .green : .white.opacity(0.7))
                }
                Button { vm.startPairing() } label: {
                    Label(vm.hasPairingFile ? L.t("pair.repair") : L.t("pair.start"),
                          systemImage: "antenna.radiowaves.left.and.right")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .tint(Color(red: 0.45, green: 0.38, blue: 1.0))
                .disabled(!networkOK)
            }
        }
        .padding(16).appsGlass(cornerRadius: 22)
    }

    private var importCard: some View {
        Button { showFilePicker = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("pair.import")).font(.headline)
                    Text(L.t("pair.importSub")).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(.white).padding(16)
        }
        .appsGlass(cornerRadius: 22)
    }
}
