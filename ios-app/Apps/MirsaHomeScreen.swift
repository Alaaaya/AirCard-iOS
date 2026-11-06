import SwiftUI

// Independently implemented visual homage to NightVibes33/FlekDeck.
// No upstream code or artwork is copied. See LICENSES/FlekDeck-inspiration.md.
struct MirsaHomeScreen<Menu: View>: View {
    let apps: [ManagedApp]
    let onLaunch: (ManagedApp) -> Void
    let onSettings: () -> Void
    let onImport: () -> Void
    let onDownloads: () -> Void
    @ViewBuilder let menu: (ManagedApp) -> Menu
    @AppStorage("mirsa.home.wallpaper") private var wallpaper = "ocean"
    @AppStorage("mirsa.home.dockIDs") private var dockIDs = "[]"
    @State private var page = 0

    private var pinnedIDs: [String] {
        guard let data = dockIDs.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    private var dockApps: [ManagedApp] {
        pinnedIDs.compactMap { id in apps.first { $0.id == id } }.prefix(4).map { $0 }
    }
    private var gridApps: [ManagedApp] { apps.filter { !pinnedIDs.contains($0.id) } }
    private var colors: [Color] {
        switch wallpaper {
        case "sunset": return [Color(red: 0.65, green: 0.26, blue: 0.20), Color(red: 0.27, green: 0.12, blue: 0.26), .black]
        case "graphite": return [Color(white: 0.27), Color(white: 0.10), .black]
        default: return [Color(red: 0.13, green: 0.42, blue: 0.62), Color(red: 0.05, green: 0.21, blue: 0.36), Color(red: 0.02, green: 0.06, blue: 0.13)]
        }
    }

    var body: some View {
        GeometryReader { geo in
            let rows = max(1, Int(max(100, geo.size.height - 180) / 118))
            let capacity = rows * 3
            let count = max(1, (gridApps.count + capacity - 1) / capacity)
            VStack(spacing: 12) {
                HStack {
                    Text("Mirsa").font(.title3.weight(.semibold))
                    Spacer()
                    Button(action: onImport) { Image(systemName: "plus").frame(width: 44, height: 44) }
                        .accessibilityLabel(L.t("empty.import"))
                    Button(action: onSettings) { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                        .accessibilityLabel(L.t("settings.title"))
                }
                .padding(.horizontal, 18)
                TabView(selection: $page) {
                    ForEach(0..<count, id: \.self) { index in
                        VStack {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                                ForEach(Array(gridApps.dropFirst(index * capacity).prefix(capacity))) { app in
                                    tile(app, compact: false)
                                }
                            }
                            if gridApps.isEmpty {
                                VStack(spacing: 16) {
                                    Image(systemName: "square.grid.3x3").font(.largeTitle)
                                    Text(apps.isEmpty ? L.t("empty.title") : tr("Your apps are in the dock", "تطبيقاتك بالدوك"))
                                    Button(L.t("empty.import"), action: onImport).buttonStyle(.bordered)
                                }.padding(.top, 40)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                HStack(spacing: 8) {
                    ForEach(0..<count, id: \.self) { index in
                        Button { withAnimation { page = index } } label: {
                            Circle().fill(.white.opacity(index == page ? 1 : 0.3)).frame(width: 7, height: 7)
                                .padding(.vertical, 8)
                        }
                        .accessibilityLabel(tr("Page \(index + 1)", "صفحة \(index + 1)"))
                        .accessibilityAddTraits(index == page ? .isSelected : [])
                    }
                }
                HStack(spacing: 12) {
                    ForEach(dockApps) { app in tile(app, compact: true) }
                    if dockApps.isEmpty {
                        VStack(spacing: 4) {
                            Image(systemName: "hand.tap").font(.title3)
                            Text(tr("Hold an app to pin it here", "اضغط مطوّل عالتطبيق لتثبّته هون"))
                                .font(.caption2).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity)
                    }
                    Button(action: onDownloads) {
                        Image(systemName: "arrow.down.circle").font(.title2).frame(width: 44, height: 58)
                    }.accessibilityLabel(tr("Downloads", "التنزيلات"))
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 88)
                .appsGlass(cornerRadius: 30)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .onChange(of: count) { _, newValue in page = min(page, newValue - 1) }
            }
            .background {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(.white.opacity(0.09)).frame(width: geo.size.width * 1.4)
                            .blur(radius: 65).offset(x: 150, y: -180)
                    }
                    .ignoresSafeArea()
            }
        }
        .foregroundStyle(.white)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func tile(_ app: ManagedApp, compact: Bool) -> some View {
        Button { onLaunch(app) } label: {
            VStack(spacing: 8) {
                Group {
                    if let icon = UIImage(contentsOfFile: AppsStore.iconURL(app.id).path) {
                        Image(uiImage: icon).resizable().scaledToFill()
                    } else {
                        Color.indigo.overlay(Text(String(app.name.prefix(1))).font(.title2.bold()))
                    }
                }
                .frame(width: compact ? 48 : 64, height: compact ? 48 : 64)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 4)
                if !compact {
                    Text(app.name).font(.system(size: 13, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, compact ? 0 : 8)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 58 : 110)
            .background {
                if !compact { RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.name)
        .contextMenu {
            Button { pin(app) } label: {
                Label(pinnedIDs.contains(app.id) ? tr("Remove from dock", "إزالة من الدوك") : tr("Pin to dock", "تثبيت بالدوك"),
                      systemImage: pinnedIDs.contains(app.id) ? "pin.slash" : "pin")
            }
            .disabled(!pinnedIDs.contains(app.id) && dockApps.count >= 4)
            Divider()
            menu(app)
        }
    }

    private func pin(_ app: ManagedApp) {
        var ids = pinnedIDs.filter { id in apps.contains { $0.id == id } }
        if ids.contains(app.id) { ids.removeAll { $0 == app.id } }
        else if ids.count < 4 { ids.append(app.id) }
        if let data = try? JSONEncoder().encode(ids), let value = String(data: data, encoding: .utf8) {
            withAnimation(.easeInOut(duration: 0.2)) { dockIDs = value }
        }
    }
}
