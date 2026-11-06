import SwiftUI

/// Personal-apps home grid with the same folder + jiggle-reorder abilities as the main home.
/// `apps` are the visible apps (hidden ones already filtered by the parent). `allAppIDs` is the full
/// ID list: hidden apps keep their folder membership, only IDs missing from `allAppIDs` are pruned.
struct PersonalAppsHome<Menu: View, Overlay: View>: View {
    let apps: [PersonalLibraryApp]
    let allAppIDs: [UUID]
    let onOpen: (PersonalLibraryApp) -> Void
    @ViewBuilder let menu: (PersonalLibraryApp) -> Menu
    /// Optional per-icon overlay (for example the signing-ring state). Parent supplies it.
    @ViewBuilder let iconOverlay: (PersonalLibraryApp) -> Overlay
    @ObservedObject var library: PersonalAppsLibrary
    @StateObject private var store = MirsaHomeLayoutStore(namespace: "personal")
    @State private var editing = false
    @State private var jiggle = false
    @State private var openFolder: String?

    init(apps: [PersonalLibraryApp], allAppIDs: [UUID], library: PersonalAppsLibrary,
         onOpen: @escaping (PersonalLibraryApp) -> Void,
         @ViewBuilder menu: @escaping (PersonalLibraryApp) -> Menu,
         @ViewBuilder iconOverlay: @escaping (PersonalLibraryApp) -> Overlay) {
        self.apps = apps; self.allAppIDs = allAppIDs; self.library = library
        self.onOpen = onOpen; self.menu = menu; self.iconOverlay = iconOverlay
    }

    private var visibleIDs: Set<String> { Set(apps.map { $0.id.uuidString }) }
    private func app(_ id: String) -> PersonalLibraryApp? { apps.first { $0.id.uuidString == id } }
    private func reconcile() {
        store.reconcile(visible: apps.map { $0.id.uuidString }, all: allAppIDs.map(\.uuidString))
    }
    private func startEditing() {
        guard !editing else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation { editing = true }
        jiggle = false
        DispatchQueue.main.async { jiggle = true }
    }

    var body: some View {
        let items = store.layout.displayItems(visible: visibleIDs)
        ZStack {
            ScrollView {
                VStack(spacing: 12) {
                    if editing {
                        HStack {
                            Spacer()
                            Button { withAnimation { editing = false } } label: {
                                Text(tr("Done", "تم")).fontWeight(.semibold).padding(.horizontal, 16).frame(height: 36)
                                    .background(.white.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                    MirsaHomeItemsGrid(store: store, items: items, editing: editing, jiggle: jiggle,
                                       onOpenFolder: { id in withAnimation(.easeOut(duration: 0.2)) { openFolder = id } },
                                       tile: { id in if let a = app(id) { tile(a) } },
                                       icon: { id in if let a = app(id) { PersonalHomeIcon(app: a, library: library) } })
                    MirsaHomeEndZone(store: store, editing: editing)
                }
                .padding(16)
            }
            if let fid = openFolder {
                MirsaFolderOverlay(store: store, folderID: fid, visible: visibleIDs,
                                   onClose: { withAnimation(.easeOut(duration: 0.2)) { openFolder = nil } },
                                   tile: { id in if let a = app(id) { tile(a) } })
            }
        }
        .onAppear(perform: reconcile)
        .onChange(of: apps.map(\.id)) { _, _ in reconcile() }
        .onChange(of: allAppIDs) { _, _ in reconcile() }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func tile(_ a: PersonalLibraryApp) -> some View {
        Button { if !editing { onOpen(a) } } label: {
            VStack(spacing: 8) {
                PersonalHomeIcon(app: a, library: library)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { iconOverlay(a) }
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 4)
                Text(a.name).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity).frame(height: 110)
            .background { RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a.name)
        .rotationEffect(.degrees(editing ? (jiggle ? 1.6 : -1.6) : 0))
        .animation(editing ? .easeInOut(duration: 0.12).repeatForever(autoreverses: true) : .default, value: jiggle)
        .onLongPressGesture(minimumDuration: 0.5) { startEditing() }
        .contextMenu {
            Button { startEditing() } label: {
                Label(tr("Edit home screen", "تعديل الشاشة الرئيسية"), systemImage: "square.grid.3x3")
            }
            Divider()
            menu(a)
        }
    }
}

extension PersonalAppsHome where Overlay == EmptyView {
    init(apps: [PersonalLibraryApp], allAppIDs: [UUID], library: PersonalAppsLibrary,
         onOpen: @escaping (PersonalLibraryApp) -> Void,
         @ViewBuilder menu: @escaping (PersonalLibraryApp) -> Menu) {
        self.init(apps: apps, allAppIDs: allAppIDs, library: library, onOpen: onOpen, menu: menu,
                  iconOverlay: { _ in EmptyView() })
    }
}

private struct PersonalHomeIcon: View {
    let app: PersonalLibraryApp
    @ObservedObject var library: PersonalAppsLibrary
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Color.indigo.overlay(Text(String(app.name.prefix(1))).font(.title3.bold())) }
        }
        .task(id: app.id) {
            image = library.icon(for: app)
            if image == nil { image = await library.ensureIcon(for: app) }
        }
    }
}
