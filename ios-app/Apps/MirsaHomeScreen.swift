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
    @AppStorage("mirsa.home.orderIDs") private var orderIDs = "[]"
    @State private var page = 0
    @State private var editing = false
    @State private var jiggle = false
    @State private var edgeTimer: Task<Void, Never>?

    private var order: [String] {
        guard let d = orderIDs.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: d)) ?? []
    }
    private func saveOrder(_ ids: [String]) {
        if let d = try? JSONEncoder().encode(ids), let v = String(data: d, encoding: .utf8) { orderIDs = v }
    }
    private func savePinned(_ ids: [String]) {
        if let d = try? JSONEncoder().encode(ids), let v = String(data: d, encoding: .utf8) {
            withAnimation(.easeInOut(duration: 0.2)) { dockIDs = v }
        }
    }
    /// Move a dragged app before target (nil = end of grid). Unpins it if it was in the dock.
    private func move(_ id: String, before target: String?) {
        guard id != target, apps.contains(where: { $0.id == id }) else { return }
        if pinnedIDs.contains(id) { savePinned(pinnedIDs.filter { $0 != id }) }
        var ids = gridApps.map(\.id).filter { $0 != id }
        let at = target.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        ids.insert(id, at: at)
        withAnimation(.spring(duration: 0.3)) { saveOrder(ids) }
    }
    private func pinByDrop(_ id: String) {
        guard apps.contains(where: { $0.id == id }) else { return }
        var ids = pinnedIDs.filter { pinnedID in pinnedID != id && apps.contains { $0.id == pinnedID } }
        guard ids.count < 4 else { return }
        ids.append(id); savePinned(ids)
    }
    private func edge(_ delta: Int, count: Int, targeted: Bool) {
        edgeTimer?.cancel()
        guard targeted else { return }
        edgeTimer = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { await MainActor.run { withAnimation { page = max(0, min(count - 1, page + delta)) } } }
        }
    }

    private var pinnedIDs: [String] {
        guard let data = dockIDs.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    private var dockApps: [ManagedApp] {
        pinnedIDs.compactMap { id in apps.first { $0.id == id } }.prefix(4).map { $0 }
    }
    private var gridApps: [ManagedApp] {
        let rest = apps.filter { !pinnedIDs.contains($0.id) }
        let o = order
        return rest.sorted { a, b in
            let i = o.firstIndex(of: a.id) ?? Int.max, j = o.firstIndex(of: b.id) ?? Int.max
            return i < j
        }
    }
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
                    if editing {
                        Button { withAnimation { editing = false } } label: {
                            Text(tr("Done", "تم")).fontWeight(.semibold).padding(.horizontal, 16).frame(height: 36)
                                .background(.white.opacity(0.2), in: Capsule())
                        }
                    }
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
                .overlay {
                    if editing {
                        HStack {
                            Color.clear.frame(width: 28).contentShape(Rectangle())
                                .dropDestination(for: String.self) { _, _ in false } isTargeted: { edge(-1, count: count, targeted: $0) }
                            Spacer()
                            Color.clear.frame(width: 28).contentShape(Rectangle())
                                .dropDestination(for: String.self) { _, _ in false } isTargeted: { edge(1, count: count, targeted: $0) }
                        }
                    }
                }
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
                .dropDestination(for: String.self) { items, _ in
                    guard editing, let id = items.first else { return false }
                    pinByDrop(id); return true
                }
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
        .onDisappear { edgeTimer?.cancel(); edgeTimer = nil }
        .foregroundStyle(.white)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func tile(_ app: ManagedApp, compact: Bool) -> some View {
        Button { if !editing { onLaunch(app) } } label: {
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
        .rotationEffect(.degrees(editing ? (jiggle ? 1.6 : -1.6) : 0))
        .animation(editing ? .easeInOut(duration: 0.12).repeatForever(autoreverses: true) : .default, value: jiggle)
        .modifier(EditDrag(enabled: editing, id: app.id, compact: compact) { dragged in
            move(dragged, before: compact ? nil : app.id)
        })
        .onLongPressGesture(minimumDuration: 0.5) {
            guard !editing else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation { editing = true }
            jiggle = false
            DispatchQueue.main.async { jiggle = true }
        }
        .contextMenu {
            Button { pin(app) } label: {
                Label(pinnedIDs.contains(app.id) ? tr("Remove from dock", "إزالة من الدوك") : tr("Pin to dock", "تثبيت بالدوك"),
                      systemImage: pinnedIDs.contains(app.id) ? "pin.slash" : "pin")
            }
            .disabled(!pinnedIDs.contains(app.id) && dockApps.count >= 4)
            Button { withAnimation { editing = true }; jiggle = false; DispatchQueue.main.async { jiggle = true } } label: {
                Label(tr("Edit home screen", "تعديل الشاشة الرئيسية"), systemImage: "square.grid.3x3")
            }
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


private struct EditDrag: ViewModifier {
    let enabled: Bool
    let id: String
    let compact: Bool
    let onDropOnto: (String) -> Void
    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(id)
                .dropDestination(for: String.self) { items, _ in
                    guard !compact, let d = items.first else { return false }
                    onDropOnto(d); return true
                }
        } else { content }
    }
}
