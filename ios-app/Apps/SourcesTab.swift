import SwiftUI

// MARK: - Model (AltStore / SideStore / Feather source format)

struct RepoApp: Identifiable, Hashable {
    var id: String { bundleID + "|" + version }
    let name: String
    let bundleID: String
    let developer: String
    let subtitle: String
    let description: String
    let version: String
    let iconURL: URL?
    let downloadURL: URL
    let size: Int64?
    let date: String?
}

struct RepoSource: Codable, Identifiable, Hashable {
    var id: String { url }
    var url: String
    var name: String
    var iconURL: String?
    var tint: String?
    var updated: Date?
    var appCount: Int = 0
}

@MainActor
final class SourcesStore: ObservableObject {
    static let shared = SourcesStore()
    private let key = "mirsa.sources.v1"

    @Published var sources: [RepoSource] = [] { didSet { save() } }
    @Published var apps: [String: [RepoApp]] = [:]   // by source url
    @Published var loading: Set<String> = []
    @Published var error: String?

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode([RepoSource].self, from: d) { sources = s }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(sources) { UserDefaults.standard.set(d, forKey: key) }
    }

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept altstore://source?url=… and sidestore://source?url=…
        if let c = URLComponents(string: s), ["altstore", "sidestore", "feather"].contains(c.scheme?.lowercased() ?? ""),
           let u = c.queryItems?.first(where: { $0.name == "url" })?.value { s = u }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let u = URL(string: s), u.host != nil else { return nil }
        return u
    }

    func add(_ raw: String) async -> Bool {
        guard let u = Self.normalize(raw) else { error = tr("That link isn't valid.", "الرابط مو صحيح."); return false }
        if sources.contains(where: { $0.url == u.absoluteString }) { return true }
        sources.append(RepoSource(url: u.absoluteString, name: u.host ?? "Source"))
        let ok = await refresh(u.absoluteString)
        if !ok { sources.removeAll { $0.url == u.absoluteString } }
        return ok
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { g in
            for s in sources { g.addTask { _ = await self.refresh(s.url) } }
        }
    }

    @discardableResult
    func refresh(_ url: String) async -> Bool {
        guard let u = URL(string: url) else { return false }
        loading.insert(url)
        defer { loading.remove(url) }
        do {
            var req = URLRequest(url: u)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                throw NSError(domain: "Mirsa", code: h.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: tr("Source answered \(h.statusCode).", "السورس ردّ بـ \(h.statusCode).")])
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Mirsa", code: 0, userInfo: [NSLocalizedDescriptionKey: tr("Not a source file.", "هذا مو ملف سورس.")])
            }
            let parsed = Self.parseApps(root, base: u)
            apps[url] = parsed
            if let i = sources.firstIndex(where: { $0.url == url }) {
                var s = sources[i]
                s.name = (root["name"] as? String) ?? s.name
                s.iconURL = (root["iconURL"] as? String) ?? (root["icon"] as? String) ?? s.iconURL
                s.tint = (root["tintColor"] as? String) ?? s.tint
                s.updated = parsed.compactMap { $0.date }.compactMap(Self.date).max() ?? s.updated
                s.appCount = parsed.count
                sources[i] = s
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    static func date(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func parseApps(_ root: [String: Any], base: URL) -> [RepoApp] {
        let list = (root["apps"] as? [[String: Any]]) ?? (root["Apps"] as? [[String: Any]]) ?? []
        func url(_ v: Any?) -> URL? {
            guard let s = v as? String, !s.isEmpty else { return nil }
            return URL(string: s, relativeTo: base)?.absoluteURL
        }
        func str(_ d: [String: Any], _ keys: String...) -> String? {
            for k in keys { if let s = d[k] as? String, !s.isEmpty { return s } }
            return nil
        }
        func int(_ v: Any?) -> Int64? {
            if let n = v as? NSNumber { return n.int64Value }
            if let s = v as? String { return Int64(s) }
            return nil
        }
        return list.compactMap { a in
            let latest = (a["versions"] as? [[String: Any]])?.first
            guard let dl = url(latest?["downloadURL"]) ?? url(a["downloadURL"]) ?? url(a["down"]) ?? url(a["url"])
            else { return nil }
            let name = str(a, "name", "title") ?? "App"
            return RepoApp(
                name: name,
                bundleID: str(a, "bundleIdentifier", "bundleID", "bundleId") ?? name,
                developer: str(a, "developerName", "developer") ?? "",
                subtitle: str(a, "subtitle") ?? "",
                description: str(a, "localizedDescription", "description") ?? "",
                version: (latest.flatMap { str($0, "version") }) ?? str(a, "version") ?? "",
                iconURL: url(a["iconURL"]) ?? url(a["icon"]),
                downloadURL: dl,
                size: int(latest?["size"]) ?? int(a["size"]),
                date: (latest.flatMap { str($0, "date") }) ?? str(a, "versionDate")
            )
        }
    }
}

extension Color {
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Views

struct SourcesTab: View {
    @StateObject private var store = SourcesStore.shared
    @State private var adding = false
    @State private var input = ""

    var body: some View {
        NavigationStack {
            List {
                if store.sources.isEmpty {
                    Text(tr("Add a source link (AltStore, SideStore or Feather format) to browse its apps.",
                            "ضيف رابط سورس (بصيغة AltStore أو SideStore أو Feather) لتتصفّح تطبيقاته."))
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(store.sources) { s in
                    NavigationLink { SourceDetailView(source: s) } label: { SourceRow(source: s, loading: store.loading.contains(s.url)) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .onDelete { store.sources.remove(atOffsets: $0) }
            }
            .listStyle(.plain)
            .refreshable { await store.refreshAll() }
            .navigationTitle(tr("Sources", "السورسات"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { input = UIPasteboard.general.string ?? ""; adding = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .alert(tr("Add Source", "أضف سورس"), isPresented: $adding) {
                TextField("https://…/source.json", text: $input)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button(tr("Cancel", "إلغاء"), role: .cancel) {}
                Button(tr("Add", "أضف")) { let t = input; Task { _ = await store.add(t) } }
            }
            .alert(tr("Source", "السورس"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
            .task { if store.apps.isEmpty { await store.refreshAll() } }
            .mirsaScreen()
        }
    }
}

private struct SourceRow: View {
    let source: RepoSource
    let loading: Bool
    var body: some View {
        let tint = Color(hex: source.tint) ?? Color(red: 0.45, green: 0.38, blue: 0.95)
        HStack(spacing: 14) {
            RemoteIcon(url: source.iconURL.flatMap(URL.init(string:)), size: 48, corner: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name).font(.title3.weight(.semibold)).foregroundStyle(.white)
                if let d = source.updated {
                    Text(tr("Last updated: ", "آخر تحديث: ") + d.formatted(date: .numeric, time: .omitted))
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            if loading { ProgressView().tint(.white) }
            else {
                Text("\(source.appCount)").font(.headline).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(.white.opacity(0.2), in: Circle())
            }
        }
        .padding(16)
        .background(tint.opacity(0.85), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct SourceDetailView: View {
    let source: RepoSource
    @ObservedObject private var store = SourcesStore.shared
    @ObservedObject private var apps = AppsStore.shared
    @State private var query = ""

    var body: some View {
        let all = store.apps[source.url] ?? []
        let shown = query.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.developer.localizedCaseInsensitiveContains(query)
        }
        List {
            ForEach(shown) { a in
                RepoAppRow(app: a, installed: apps.apps.first { $0.id == a.bundleID })
                    .listRowBackground(Color.clear)
            }
            if all.isEmpty && !store.loading.contains(source.url) {
                Text(tr("No apps in this source.", "ما في تطبيقات بهالسورس.")).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .searchable(text: $query)
        .refreshable { await store.refresh(source.url) }
        .navigationTitle(source.name)
        .mirsaScreen()
    }
}

private struct RepoAppRow: View {
    let app: RepoApp
    let installed: ManagedApp?
    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 12) {
            RemoteIcon(url: app.iconURL, size: 52, corner: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline).lineLimit(1)
                Text([app.developer, app.version.isEmpty ? nil : "v" + app.version]
                        .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !app.subtitle.isEmpty {
                    Text(app.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { install() } label: {
                Text(buttonTitle).font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(AppsStore.shared.busy != nil)
        }
        .contentShape(Rectangle())
        .onTapGesture { showInfo = true }
        .sheet(isPresented: $showInfo) { RepoAppInfo(app: app, install: install) }
    }

    private var buttonTitle: String {
        guard let i = installed else { return tr("GET", "تثبيت") }
        return i.version == app.version || app.version.isEmpty ? tr("OPEN", "مثبّت") : tr("UPDATE", "تحديث")
    }

    private func install() {
        showInfo = false
        let target = installed?.location   // update keeps its place; new apps ask Container or Real
        AppViewModel.shared?.selectedTab = .apps
        Task { await AppsStore.shared.installFromURL(app.downloadURL, location: target) }
    }
}

private struct RepoAppInfo: View {
    let app: RepoApp
    let install: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        RemoteIcon(url: app.iconURL, size: 72, corner: 16)
                        VStack(alignment: .leading) {
                            Text(app.name).font(.title2.bold())
                            Text(app.developer).foregroundStyle(.secondary)
                        }
                    }
                    Button(action: install) {
                        Text(tr("Install", "ثبّت")).bold().frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    HStack {
                        if !app.version.isEmpty { Label("v" + app.version, systemImage: "tag") }
                        if let s = app.size { Label(ByteCountFormatter.string(fromByteCount: s, countStyle: .file), systemImage: "internaldrive") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(app.description).font(.body)
                }
                .padding()
            }
            .mirsaScreen()
        }
        .presentationDetents([.medium, .large])
    }
}

struct RemoteIcon: View {
    let url: URL?
    let size: CGFloat
    let corner: CGFloat
    var body: some View {
        AsyncImage(url: url) { img in img.resizable().scaledToFill() }
            placeholder: { Image(systemName: "app.dashed").font(.system(size: size * 0.45)).foregroundStyle(.secondary) }
            .frame(width: size, height: size)
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
