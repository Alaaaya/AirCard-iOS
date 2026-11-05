import SwiftUI

/// Mirsa's look for the older Form/ScrollView screens: aurora background,
/// translucent rows, clear navigation bar, purple accent.
struct MirsaForm<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        Form { content() }
            .mirsaScreen()
    }
}

struct MirsaScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView { content() }
            .mirsaScreen()
    }
}

extension View {
    func mirsaScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AuroraBackground().ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            .tint(Color(red: 0.62, green: 0.55, blue: 1.0))
            .environment(\.defaultMinListRowHeight, 50)
            .preferredColorScheme(.dark)
    }
}

// MARK: - Themes (Settings › Theme): Classic or Liquid Glass

enum MirsaTheme: String, CaseIterable, Identifiable {
    case liquid, classic
    static let key = "mirsa.theme"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .liquid: return tr("Liquid Glass", "زجاج سائل")
        case .classic: return tr("Classic", "الكلاسيكي")
        }
    }
    static var isLiquid: Bool { (UserDefaults.standard.string(forKey: key) ?? MirsaTheme.liquid.rawValue) == MirsaTheme.liquid.rawValue }
}

extension View {
    func appsGlass(cornerRadius: CGFloat = 24, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(ThemedGlass(shape: .rect(cornerRadius: cornerRadius), tint: tint, interactive: interactive))
    }
    func appsGlassCapsule(tint: Color? = nil) -> some View {
        modifier(ThemedGlass(shape: .capsule, tint: tint, interactive: true))
    }
}

enum GlassShapeKind { case rect(cornerRadius: CGFloat), capsule }

struct ThemedGlass: ViewModifier {
    let shape: GlassShapeKind
    let tint: Color?
    let interactive: Bool
    @AppStorage(MirsaTheme.key) private var theme = MirsaTheme.liquid.rawValue

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == MirsaTheme.liquid.rawValue {
            switch shape {
            case .rect(let r): content.modifier(LiquidGlass(shape: RoundedRectangle(cornerRadius: r, style: .continuous), tint: tint, depth: r >= 20 ? 1 : 0.6))
            case .capsule: content.modifier(LiquidGlass(shape: Capsule(), tint: tint, depth: 0.6))
            }
        } else {
            switch shape {
            case .rect(let r): content.appsGlassClassic(cornerRadius: r, tint: tint, interactive: interactive)
            case .capsule: content.appsGlassCapsuleClassic(tint: tint)
            }
        }
    }
}

/// The design's glass: blurred, white diagonal sheen, hairline border, a bright
/// top edge and a soft deep shadow. A tint washes the card in that colour.
struct LiquidGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    var depth: Double = 1

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial).opacity(0.75)
                    if let tint {
                        shape.fill(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.18)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    shape.fill(LinearGradient(stops: [
                        .init(color: .white.opacity(0.20), location: 0),
                        .init(color: .white.opacity(0.05), location: 0.55),
                        .init(color: .white.opacity(0.12), location: 1),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .shadow(color: .black.opacity(0.38 * depth), radius: 20 * depth, y: 16 * depth)
            }
            .overlay {
                shape.strokeBorder(.white.opacity(0.26), lineWidth: 1)
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .clear, .clear, .white.opacity(0.08)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
            }
            .contentShape(shape)
    }
}

/// Base #090A1E with violet, cyan and pink light and two floating orbs.
struct LiquidBackground: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Color(red: 9 / 255, green: 10 / 255, blue: 30 / 255)
                RadialGradient(colors: [Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255).opacity(0.8), .clear],
                               center: UnitPoint(x: 0.88, y: 0.06), startRadius: 0, endRadius: 300)
                RadialGradient(colors: [Color(red: 34 / 255, green: 211 / 255, blue: 238 / 255).opacity(0.5), .clear],
                               center: UnitPoint(x: 0, y: 0.46), startRadius: 0, endRadius: 280)
                RadialGradient(colors: [Color(red: 236 / 255, green: 72 / 255, blue: 153 / 255).opacity(0.42), .clear],
                               center: UnitPoint(x: 1, y: 0.88), startRadius: 0, endRadius: 310)
                TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255),
                                                          Color(red: 34 / 255, green: 211 / 255, blue: 238 / 255)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 190, height: 190)
                            .opacity(0.55).blur(radius: 6)
                            .position(x: w - 65 + sin(t * 0.20) * 14, y: 245 + cos(t * 0.17) * 18)
                        Circle()
                            .fill(LinearGradient(colors: [Color(red: 129 / 255, green: 140 / 255, blue: 248 / 255),
                                                          Color(red: 192 / 255, green: 132 / 255, blue: 252 / 255)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 120, height: 120)
                            .opacity(0.5).blur(radius: 4)
                            .position(x: 100 + cos(t * 0.15) * 16, y: min(h * 0.58, 490) + sin(t * 0.22) * 20)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Floating glass tab bar (Liquid Glass theme)

struct LiquidTabItem: Identifiable {
    let tab: AppTab
    let title: String
    let icon: String
    var id: String { tab.rawValue }
}

struct LiquidTabBar: View {
    @Binding var selection: AppTab
    let items: [LiquidTabItem]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let on = selection == item.tab
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { selection = item.tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon).font(.system(size: 19, weight: on ? .semibold : .regular))
                        Text(item.title).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
                    }
                    .foregroundStyle(on ? .white : .white.opacity(0.68))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if on {
                            Capsule()
                                .fill(LinearGradient(colors: [Color(red: 96 / 255, green: 165 / 255, blue: 250 / 255).opacity(0.42),
                                                              Color(red: 96 / 255, green: 165 / 255, blue: 250 / 255).opacity(0.16)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.32), lineWidth: 1))
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(height: 72)
        .modifier(LiquidGlass(shape: Capsule(), tint: nil, depth: 1.1))
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }
}
