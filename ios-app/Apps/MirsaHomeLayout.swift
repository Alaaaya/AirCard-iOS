import Foundation

/// Persisted home-screen layout shared by the main and personal homes.
/// Items are stored in physical left-to-right order, independent of UI language.
struct MirsaHomeFolder: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var appIDs: [String]
}

enum MirsaHomeItem: Codable, Equatable, Identifiable {
    case app(String)
    case folder(MirsaHomeFolder)

    /// Stable drag/drop identity: "app:<id>" or "folder:<id>".
    var id: String {
        switch self {
        case .app(let id): return MirsaHomeLayout.appItemID(id)
        case .folder(let f): return MirsaHomeLayout.folderItemID(f.id)
        }
    }
}

struct MirsaHomeLayout: Codable, Equatable {
    var version = 1
    var items: [MirsaHomeItem] = []

    static func appItemID(_ id: String) -> String { "app:" + id }
    static func folderItemID(_ id: String) -> String { "folder:" + id }
    static func parseApp(_ itemID: String) -> String? { itemID.hasPrefix("app:") ? String(itemID.dropFirst(4)) : nil }
    static func parseFolder(_ itemID: String) -> String? { itemID.hasPrefix("folder:") ? String(itemID.dropFirst(7)) : nil }

    /// Migration from the old flat order list (main home only).
    static func fromLegacy(order: [String]) -> MirsaHomeLayout {
        var l = MirsaHomeLayout()
        l.items = order.map { .app($0) }
        l.normalize()
        return l
    }

    var allAppIDs: [String] {
        items.flatMap { item -> [String] in
            switch item {
            case .app(let id): return [id]
            case .folder(let f): return f.appIDs
            }
        }
    }

    func folder(_ id: String) -> MirsaHomeFolder? {
        for case .folder(let f) in items where f.id == id { return f }
        return nil
    }

    // MARK: normalisation

    /// Removes duplicate IDs (first wins), empty folders, and dissolves one-member folders.
    mutating func normalize() {
        var seen = Set<String>()
        var out: [MirsaHomeItem] = []
        var folderSeen = Set<String>()
        for item in items {
            switch item {
            case .app(let id):
                if seen.insert(id).inserted { out.append(.app(id)) }
            case .folder(var f):
                guard folderSeen.insert(f.id).inserted else { continue }
                f.appIDs = f.appIDs.filter { seen.insert($0).inserted }
                if f.appIDs.count == 1 { out.append(.app(f.appIDs[0])) }
                else if f.appIDs.count > 1 { out.append(.folder(f)) }
            }
        }
        items = out
    }

    /// Reconcile with the currently visible apps.
    /// - Never removes IDs just because they are not visible (they may be hidden).
    /// - If `all` is given, IDs missing from it are removed (real deletion).
    /// - `excluded` (for example docked apps) are taken out of the grid.
    mutating func reconcile(visible: [String], all: [String]? = nil, excluded: Set<String> = []) {
        normalize()
        let known = all.map(Set.init)
        var next: [MirsaHomeItem] = []
        for item in items {
            switch item {
            case .app(let id):
                if excluded.contains(id) { continue }
                if let k = known, !k.contains(id) { continue }
                next.append(item)
            case .folder(var f):
                f.appIDs = f.appIDs.filter { id in
                    !excluded.contains(id) && (known?.contains(id) ?? true)
                }
                next.append(.folder(f))
            }
        }
        items = next
        normalize()
        let present = Set(allAppIDs)
        for id in visible where !present.contains(id) && !excluded.contains(id) { items.append(.app(id)) }
    }

    /// What the grid shows: hidden apps filtered out, folders with no visible members skipped.
    func displayItems(visible: Set<String>) -> [MirsaHomeItem] {
        items.compactMap { item in
            switch item {
            case .app(let id): return visible.contains(id) ? item : nil
            case .folder(var f):
                f.appIDs = f.appIDs.filter { visible.contains($0) }
                return f.appIDs.isEmpty ? nil : .folder(f)
            }
        }
    }

    // MARK: editing

    /// Detaches an app from top level or any folder. Does not normalise.
    @discardableResult
    private mutating func detachApp(_ id: String) -> Bool {
        var found = false
        var next: [MirsaHomeItem] = []
        for item in items {
            switch item {
            case .app(let a):
                if a == id { found = true } else { next.append(item) }
            case .folder(var f):
                if let i = f.appIDs.firstIndex(of: id) { f.appIDs.remove(at: i); found = true }
                next.append(.folder(f))
            }
        }
        items = next
        return found
    }

    /// Removes an app from the layout entirely (for example when it is pinned to the dock).
    mutating func remove(app id: String) { detachApp(id); normalize() }

    private func topIndex(_ itemID: String) -> Int? { items.firstIndex { $0.id == itemID } }

    /// Reorder: put the dragged item (app or folder) before `target` item (nil = end).
    @discardableResult
    mutating func move(_ dragged: String, before target: String?) -> Bool {
        guard dragged != target else { return false }
        let item: MirsaHomeItem
        if let a = Self.parseApp(dragged) {
            detachApp(a); item = .app(a)
        } else if let fid = Self.parseFolder(dragged), let i = items.firstIndex(where: { $0.id == dragged }) {
            guard case .folder = items[i] else { return false }
            item = items.remove(at: i); _ = fid
        } else { return false }
        let at = target.flatMap { topIndex($0) } ?? items.count
        items.insert(item, at: at)
        normalize()
        return true
    }

    /// Drop `dragged` onto `target`. App on app creates a folder, app on folder joins it.
    /// Folder dragged onto something is a plain reorder.
    @discardableResult
    mutating func drop(_ dragged: String, onto target: String, newFolderID: String = UUID().uuidString,
                       newFolderName: String = "Folder") -> Bool {
        guard dragged != target else { return false }
        guard let app = Self.parseApp(dragged) else { return move(dragged, before: target) }
        guard topIndex(target) != nil else { return false }
        if let targetApp = Self.parseApp(target) {
            guard targetApp != app else { return false }
            detachApp(app)
            guard let i = topIndex(target) else { items.append(.app(app)); normalize(); return false }
            items[i] = .folder(MirsaHomeFolder(id: newFolderID, name: newFolderName, appIDs: [targetApp, app]))
        } else if let fid = Self.parseFolder(target) {
            detachApp(app)
            guard let i = items.firstIndex(where: { $0.id == target }), case .folder(var f) = items[i] else {
                items.append(.app(app)); normalize(); return false
            }
            f.appIDs.append(app)
            items[i] = .folder(f); _ = fid
        }
        normalize()
        return true
    }

    /// Move an app out of its folder to the top level, right after that folder.
    @discardableResult
    mutating func removeFromFolder(_ app: String, folder fid: String) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == Self.folderItemID(fid) }),
              case .folder(var f) = items[i], let j = f.appIDs.firstIndex(of: app) else { return false }
        f.appIDs.remove(at: j)
        items[i] = .folder(f)
        items.insert(.app(app), at: i + 1)
        normalize()
        return true
    }

    /// Reorder inside a folder (nil = end). Adds the app if it came from elsewhere.
    @discardableResult
    mutating func moveInFolder(_ app: String, folder fid: String, before target: String?) -> Bool {
        guard folder(fid) != nil, app != target else { return false }
        detachApp(app)
        guard let i = items.firstIndex(where: { $0.id == Self.folderItemID(fid) }), case .folder(var f) = items[i] else {
            items.append(.app(app)); normalize(); return false
        }
        let at = target.flatMap { f.appIDs.firstIndex(of: $0) } ?? f.appIDs.count
        f.appIDs.insert(app, at: at)
        items[i] = .folder(f)
        normalize()
        return true
    }

    mutating func rename(folder fid: String, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == Self.folderItemID(fid) }), case .folder(var f) = items[i] else { return }
        f.name = String(name.prefix(40))
        items[i] = .folder(f)
    }
}

/// Persists a namespaced layout ("main" or "personal") in UserDefaults.
@MainActor
final class MirsaHomeLayoutStore: ObservableObject {
    @Published private(set) var layout: MirsaHomeLayout
    let namespace: String
    private let defaults: UserDefaults
    private var key: String { "mirsa.home.layout.v1." + namespace }

    init(namespace: String, legacyOrderKey: String? = nil, defaults: UserDefaults = .standard) {
        self.namespace = namespace
        self.defaults = defaults
        if let data = defaults.data(forKey: "mirsa.home.layout.v1." + namespace),
           let l = try? JSONDecoder().decode(MirsaHomeLayout.self, from: data) {
            layout = l
        } else if let k = legacyOrderKey, let s = defaults.string(forKey: k),
                  let d = s.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: d) {
            layout = .fromLegacy(order: ids)
        } else {
            layout = MirsaHomeLayout()
        }
    }

    /// Applies a change and saves only if something changed.
    func mutate(_ change: (inout MirsaHomeLayout) -> Void) {
        var l = layout
        change(&l)
        guard l != layout else { return }
        layout = l
        if let d = try? JSONEncoder().encode(l) { defaults.set(d, forKey: key) }
    }

    func reconcile(visible: [String], all: [String]? = nil, excluded: Set<String> = []) {
        mutate { $0.reconcile(visible: visible, all: all, excluded: excluded) }
    }
}
