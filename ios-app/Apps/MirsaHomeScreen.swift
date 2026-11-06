import SwiftUI

// Independently implemented visual homage to NightVibes33/FlekDeck.
// No upstream code or artwork is copied. See LICENSES/FlekDeck-inspiration.md.
struct MirsaHomeScreen<Menu: View>: View {
    /// Visible apps only (hidden ones already filtered out by the parent).
    let apps: [ManagedApp]
    /// Every app ID including hidden ones. Required: hidden folder members and hidden docked apps are preserved.
    let allAppIDs: [String]
    let onLaunch: (ManagedApp) -> Void
    let onSettings: () -> Void
    let onImport: () -> Void
    let onDownloads: () -> Void
    @ViewBuilder let menu: (ManagedApp) -> Menu
    @AppStorage("mirsa.home.wallpaper") private var wallpaper = "ocean"
    @AppStorage("mirsa.home.dockIDs") private var dockIDs = "[]"
    @StateObject private var layoutStore = MirsaHomeLayoutStore(namespace: "main", legacyOrderKey: "mirsa.home.orderIDs")
    @State private var openFolder: String?
    @State private var page = 0
    @State private var editing = false
    @State private var jiggle = false
    @State private var edgeTimer: Task<Void, Never>?

    private func savePinned(_ ids: [String]) {
        if let d = try? JSONEncoder().encode(ids), let v = String(data: d, encoding: .utf8) {
            withAnimation(.easeInOut(duration: 0.2)) { dockIDs = v }
        }
    }
    private func unpinIfPinned(_ id: String) {
        if pinnedIDs.contains(id) { savePinned(pinnedIDs.filter { $0 != id }) }
    }
    private func pinByDrop(_ id: String) {
        guard apps.contains(where: { $0.id == id }) else { return }
        let known = Set(allAppIDs)
        var ids = pinnedIDs.filter { $0 != id && known.contains($0) }
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
    private var gridApps: [ManagedApp] { apps.filter { !pinnedIDs.contains($0.id) } }
    private var gridItems: [MirsaHomeItem] {
        layoutStore.layout.displayItems(visible: Set(gridApps.map(\.id)))
    }
    private func appByID(_ id: String) -> ManagedApp? { apps.first { $0.id == id } }
    private func reconcileLayout() {
        layoutStore.reconcile(visible: apps.map(\.id), all: allAppIDs, excluded: Set(pinnedIDs))
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
            let items = gridItems
            let count = max(1, (items.count + capacity - 1) / capacity)
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
                            MirsaHomeItemsGrid(store: layoutStore,
                                               items: Array(items.dropFirst(index * capacity).prefix(capacity)),
                                               editing: editing, jiggle: jiggle,
                                               onOpenFolder: { id in withAnimation(.easeOut(duration: 0.2)) { openFolder = id } },
                                               onPlaced: { unpinIfPinned($0) },
                                               tile: { id in if let app = appByID(id) { tile(app, compact: false) } },
                                               icon: { id in if let app = appByID(id) { appIcon(app) } })
                            if index == count - 1 { MirsaHomeEndZone(store: layoutStore, editing: editing, onPlaced: { unpinIfPinned($0) }) }
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
                    guard editing, let id = items.first.flatMap(MirsaHomeLayout.parseApp) else { return false }
                    pinByDrop(id); return true
                }
                .onChange(of: count) { _, newValue in page = min(page, newValue - 1) }
            }
            .overlay {
                if let fid = openFolder {
                    MirsaFolderOverlay(store: layoutStore, folderID: fid, visible: Set(gridApps.map(\.id)),
                                       onClose: { withAnimation(.easeOut(duration: 0.2)) { openFolder = nil } },
                                       tile: { id in if let app = appByID(id) { tile(app, compact: false) } })
                }
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
        .onAppear(perform: reconcileLayout)
        .onChange(of: apps.map(\.id)) { _, _ in reconcileLayout() }
        .onChange(of: allAppIDs) { _, _ in reconcileLayout() }
        .onChange(of: dockIDs) { _, _ in reconcileLayout() }
        .onDisappear { edgeTimer?.cancel(); edgeTimer = nil }
        .foregroundStyle(.white)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func appIcon(_ app: ManagedApp) -> some View {
        Group {
            if let icon = UIImage(contentsOfFile: AppsStore.iconURL(app.id).path) {
                Image(uiImage: icon).resizable().scaledToFill()
            } else {
                Color.indigo.overlay(Text(String(app.name.prefix(1))).font(.caption.bold()))
            }
        }
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
        .modifier(DockDrag(enabled: editing && compact, id: app.id))
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
            .disabled(!pinnedIDs.contains(app.id) && pinnedIDs.filter { Set(allAppIDs).contains($0) }.count >= 4)
            Button { withAnimation { editing = true }; jiggle = false; DispatchQueue.main.async { jiggle = true } } label: {
                Label(tr("Edit home screen", "تعديل الشاشة الرئيسية"), systemImage: "square.grid.3x3")
            }
            Divider()
            menu(app)
        }
    }

    private func pin(_ app: ManagedApp) {
        let known = Set(allAppIDs)
        var ids = pinnedIDs.filter { known.contains($0) }
        if ids.contains(app.id) { ids.removeAll { $0 == app.id } }
        else if ids.count < 4 { ids.append(app.id) }
        if let data = try? JSONEncoder().encode(ids), let value = String(data: data, encoding: .utf8) {
            withAnimation(.easeInOut(duration: 0.2)) { dockIDs = value }
        }
    }
}


private struct DockDrag: ViewModifier {
    let enabled: Bool
    let id: String
    func body(content: Content) -> some View {
        if enabled { content.draggable(MirsaHomeLayout.appItemID(id)) } else { content }
    }
}


// MARK: - Shared grid + folders (used by main and personal homes)

/// Grid page content. `tile` renders a full app cell, `icon` only its icon (for folder previews).
struct MirsaHomeItemsGrid<Tile: View, Icon: View>: View {
    @ObservedObject var store: MirsaHomeLayoutStore
    let items: [MirsaHomeItem]
    let editing: Bool
    let jiggle: Bool
    let onOpenFolder: (String) -> Void
    /// Called after an app was dropped into the grid (main home unpins docked apps here).
    var onPlaced: (String) -> Void = { _ in }
    @ViewBuilder let tile: (String) -> Tile
    @ViewBuilder let icon: (String) -> Icon

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(items) { item in
                MirsaHomeCell(editing: editing, itemID: item.id,
                              onReorder: { dragged in reorder(dragged, before: item.id) },
                              onOnto: { dragged in dropOnto(dragged, target: item.id) }) {
                    switch item {
                    case .app(let id): tile(id)
                    case .folder(let f): folderCell(f)
                    }
                }
            }
        }
    }

    private func reorder(_ dragged: String, before target: String) -> Bool {
        var ok = false
        withAnimation(.spring(duration: 0.3)) { store.mutate { ok = $0.move(dragged, before: target) } }
        if ok, let a = MirsaHomeLayout.parseApp(dragged) { onPlaced(a) }
        return ok
    }
    private func dropOnto(_ dragged: String, target: String) -> Bool {
        var ok = false
        let name = tr("Folder", "مجلد")
        withAnimation(.spring(duration: 0.3)) { store.mutate { ok = $0.drop(dragged, onto: target, newFolderName: name) } }
        if ok, let a = MirsaHomeLayout.parseApp(dragged) { onPlaced(a) }
        return ok
    }

    private func folderCell(_ f: MirsaHomeFolder) -> some View {
        Button { if !editing { onOpenFolder(f.id) } } label: {
            VStack(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 2), spacing: 4) {
                    ForEach(Array(f.appIDs.prefix(4)), id: \.self) { id in
                        icon(id).frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(f.name).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity).frame(height: 110)
            .background { RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(f.name)
        .rotationEffect(.degrees(editing ? (jiggle ? 1.6 : -1.6) : 0))
        .animation(editing ? .easeInOut(duration: 0.12).repeatForever(autoreverses: true) : .default, value: jiggle)
    }
}

/// One grid cell. When editing it is draggable and has two drop zones: a thin left strip that
/// reorders, and the rest which drops onto the item (folder create / join).
struct MirsaHomeCell<Content: View>: View {
    let editing: Bool
    let itemID: String
    let onReorder: (String) -> Bool
    let onOnto: (String) -> Bool
    @ViewBuilder let content: () -> Content
    @State private var reorderHover = false
    @State private var ontoHover = false

    var body: some View {
        if editing {
            content()
                .draggable(itemID)
                .scaleEffect(ontoHover ? 1.06 : 1)
                .animation(.easeOut(duration: 0.15), value: ontoHover)
                .overlay {
                    GeometryReader { g in
                        HStack(spacing: 0) {
                            Color.clear.frame(width: g.size.width * 0.26).contentShape(Rectangle())
                                .dropDestination(for: String.self) { items, _ in
                                    guard let d = items.first else { return false }
                                    return onReorder(d)
                                } isTargeted: { reorderHover = $0 }
                            Color.clear.contentShape(Rectangle())
                                .dropDestination(for: String.self) { items, _ in
                                    guard let d = items.first else { return false }
                                    return onOnto(d)
                                } isTargeted: { ontoHover = $0 }
                        }
                    }
                }
                .overlay(alignment: .leading) {
                    if reorderHover { Capsule().fill(.white).frame(width: 3).padding(.vertical, 6).offset(x: -5) }
                }
        } else { content() }
    }
}

/// Zone at the end of the grid so items can be dropped last.
struct MirsaHomeEndZone: View {
    @ObservedObject var store: MirsaHomeLayoutStore
    let editing: Bool
    var onPlaced: (String) -> Void = { _ in }
    var body: some View {
        if editing {
            Color.clear.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    guard let d = items.first else { return false }
                    var ok = false
                    withAnimation(.spring(duration: 0.3)) { store.mutate { ok = $0.move(d, before: nil) } }
                    if ok, let a = MirsaHomeLayout.parseApp(d) { onPlaced(a) }
                    return ok
                }
        }
    }
}

/// Glass overlay that shows one folder: editable name, drag apps within, drop outside to remove.
struct MirsaFolderOverlay<Tile: View>: View {
    @ObservedObject var store: MirsaHomeLayoutStore
    let folderID: String
    let visible: Set<String>
    let onClose: () -> Void
    @ViewBuilder let tile: (String) -> Tile

    private var folder: MirsaHomeFolder? { store.layout.folder(folderID) }
    private var name: Binding<String> {
        Binding(get: { folder?.name ?? "" }, set: { v in store.mutate { $0.rename(folder: folderID, to: v) } })
    }

    var body: some View {
        if let f = folder {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea()
                    .onTapGesture(perform: onClose)
                    .dropDestination(for: String.self) { items, _ in
                        guard let a = items.first.flatMap(MirsaHomeLayout.parseApp) else { return false }
                        withAnimation { store.mutate { _ = $0.removeFromFolder(a, folder: folderID) } }
                        return true
                    }
                VStack(spacing: 14) {
                    TextField(tr("Folder", "مجلد"), text: name)
                        .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        .textInputAutocapitalization(.words)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(f.appIDs.filter { visible.contains($0) }, id: \.self) { id in
                            tile(id)
                                .draggable(MirsaHomeLayout.appItemID(id))
                                .dropDestination(for: String.self) { items, _ in
                                    guard let a = items.first.flatMap(MirsaHomeLayout.parseApp) else { return false }
                                    withAnimation { store.mutate { _ = $0.moveInFolder(a, folder: folderID, before: id) } }
                                    return true
                                }
                        }
                    }
                    Text(tr("Drag an app outside to remove it", "اسحب التطبيق لبرا ليطلع من المجلد"))
                        .font(.caption).opacity(0.7)
                }
                .padding(18)
                .frame(maxWidth: 360)
                .appsGlass(cornerRadius: 32)
                .padding(.horizontal, 20)
                .dropDestination(for: String.self) { items, _ in
                    guard let a = items.first.flatMap(MirsaHomeLayout.parseApp) else { return false }
                    withAnimation { store.mutate { _ = $0.moveInFolder(a, folder: folderID, before: nil) } }
                    return true
                }
            }
            .foregroundStyle(.white)
            .environment(\.layoutDirection, .leftToRight)
            .transition(.opacity)
        } else {
            Color.clear.onAppear(perform: onClose)
        }
    }
}
