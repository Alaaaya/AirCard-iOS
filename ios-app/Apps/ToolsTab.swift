import SwiftUI

/// Second tab: pairing and the device tools, all in one place, in Mirsa's design.
struct ToolsTab: View {
    @EnvironmentObject var vm: AppViewModel
    enum Section: String, CaseIterable, Identifiable {
        case pairing, device, wallet, passcode, wallpapers
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .pairing: return "antenna.radiowaves.left.and.right"
            case .device: return "iphone.gen3"
            case .wallet: return "creditcard.fill"
            case .passcode: return "lock.circle.fill"
            case .wallpapers: return "photo.stack.fill"
            }
        }
    }
    @State private var section: Section = .pairing
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 0) {
            picker
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AuroraBackground().ignoresSafeArea(edges: .top))
            Group {
                switch section {
                case .pairing: SetupPairingSheet(showsClose: false)
                case .device: DeviceToolsView()
                case .wallet: WalletCardsTab()
                case .passcode: PasscodeThemeTab()
                case .wallpapers: TendiesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
    }

    private var picker: some View {
        HStack(spacing: 4) {
            ForEach(Section.allCases) { s in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { section = s }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: s.icon).font(.system(size: 16, weight: .semibold))
                        Text(s == .device ? tr("Device", "الجهاز") : L.t("tools.\(s.rawValue)")).font(.caption2.weight(.semibold)).lineLimit(1)
                    }
                    .foregroundStyle(section == s ? .white : .white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        if section == s {
                            Capsule().fill(Color.white.opacity(0.16))
                                .matchedGeometryEffect(id: "sel", in: ns)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .appsGlassCapsule()
    }
}
