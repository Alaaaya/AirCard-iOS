import SwiftUI

// MARK: - Model (AltStore / SideStore / Feather source format)

/// Copy/share of a source's stored URL. Only plain http(s) URLs without embedded credentials are allowed.
enum SourceURLAction {
    static func shareableURL(_ stored: String) -> URL? {
        let t = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let c = URLComponents(string: t),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, let u = c.url else { return nil }
        return u
    }
    @MainActor static func copy(_ stored: String) {
        guard let u = shareableURL(stored) else { return }
        UIPasteboard.general.string = u.absoluteString
    }
}

private struct SharedSourceURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

private struct SourceShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private struct SourceURLButtons: View {
    let stored: String
    @Binding var sharing: URL?
    var body: some View {
        let ok = SourceURLAction.shareableURL(stored) != nil
        Button { SourceURLAction.copy(stored) } label: { Label(tr("Copy URL", "نسخ الرابط"), systemImage: "doc.on.doc") }.disabled(!ok)
        Button { sharing = SourceURLAction.shareableURL(stored) } label: { Label(tr("Share URL", "مشاركة الرابط"), systemImage: "square.and.arrow.up") }.disabled(!ok)
    }
}

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
    var screenshots: [URL] = []
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
    @Published var updatingAll = false
    @Published var hiddenURLs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "mirsa.sources.hidden") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenURLs), forKey: "mirsa.sources.hidden") }
    }

    var visibleSources: [RepoSource] { sources.filter { !hiddenURLs.contains($0.url) } }
    var hiddenSources: [RepoSource] { sources.filter { hiddenURLs.contains($0.url) } }

    func moveVisible(from offsets: IndexSet, to destination: Int) {
        var reordered = visibleSources
        reordered.move(fromOffsets: offsets, toOffset: destination)
        var iterator = reordered.makeIterator()
        sources = sources.map { hiddenURLs.contains($0.url) ? $0 : iterator.next()! }
    }

    /// One candidate per installed app, visible source order breaks equal-version ties.
    func availableUpdates() -> [(RepoApp, AppLocation)] {
        AppsStore.shared.apps.compactMap { installed in
            let candidates = visibleSources.flatMap { apps[$0.url] ?? [] }.filter {
                $0.bundleID == installed.id && !$0.version.isEmpty &&
                $0.version.compare(installed.version, options: .numeric) == .orderedDescending
            }
            guard let newest = candidates.max(by: {
                $0.version.compare($1.version, options: .numeric) == .orderedAscending
            }) else { return nil }
            return (newest, installed.location)
        }
    }

    func updateAll() async {
        guard !updatingAll, AppsStore.shared.busy == nil else { return }
        updatingAll = true
        defer { updatingAll = false }
        await refreshAll()
        let queue = availableUpdates()
        for (app, location) in queue {
            guard !Task.isCancelled else { break }
            AppViewModel.shared?.selectedTab = .apps
            if !(await AppsStore.shared.installFromURL(app.downloadURL, location: location, appID: app.bundleID)) { break }
        }
    }


    /// Sources that ship with Mirsa: present on first launch (added once, so a
    /// user who deletes one keeps it deleted).
    static let builtIn: [(url: String, name: String)] = [
        ("https://repository.apptesters.org", "AppTesters IPA Repo"),
        ("https://github.com/Alaaaya/Mirsa/releases/download/setup/source.json", "Mirsa"),
        ("https://itslevii.dev/repo.json", "itslevii"),
        ("https://raw.githubusercontent.com/Sami-Wali/ryP0-repository/main/repo.json", "ryP0"),
    ]
    private let seededKey = "mirsa.sources.builtin.v2"

    init() {
        var list: [RepoSource] = []
        if let d = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode([RepoSource].self, from: d) { list = s }
        if !UserDefaults.standard.bool(forKey: seededKey) {
            func norm(_ u: String) -> String { u.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            for b in Self.builtIn where !list.contains(where: { norm($0.url) == norm(b.url) }) {
                list.append(RepoSource(url: b.url, name: b.name))
            }
            UserDefaults.standard.set(true, forKey: seededKey)
        }
        sources = list
        save()
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
            for s in visibleSources { g.addTask { _ = await self.refresh(s.url) } }
        }
    }

    @discardableResult
    func refresh(_ url: String) async -> Bool {
        guard let u = URL(string: url) else { return false }
        // A copied GitHub download link is a signed URL that expires within an hour.
        if u.host?.contains("release-assets.githubusercontent.com") == true || u.host?.contains("objects.githubusercontent.com") == true {
            error = tr("That's a temporary GitHub download link and it expires. Use the release link (github.com/…/releases/download/…) instead.",
                       "هاد رابط تحميل مؤقت من GitHub وبينتهي. استعمل رابط الإصدار github.com/…/releases/download/… بداله.")
            return false
        }
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
            let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let root: [String: Any]? = (json as? [String: Any]) ?? ((json as? [[String: Any]]).map { ["apps": $0] })
            guard let root else {
                throw NSError(domain: "Mirsa", code: 0, userInfo: [NSLocalizedDescriptionKey: tr("Not a source file.", "هذا مو ملف سورس.")])
            }
            let parsed = Self.parseApps(root, base: u)
            apps[url] = parsed
            if let i = sources.firstIndex(where: { $0.url == url }) {
                var s = sources[i]
                let meta = (root["META"] as? [String: Any]) ?? (root["meta"] as? [String: Any]) ?? [:]
                s.name = (root["name"] as? String) ?? (meta["repoName"] as? String) ?? (meta["name"] as? String) ?? s.name
                s.iconURL = (root["iconURL"] as? String) ?? (root["icon"] as? String) ?? (meta["repoIcon"] as? String) ?? s.iconURL
                s.tint = (root["tintColor"] as? String) ?? (root["tint"] as? String) ?? s.tint
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
        // AltStore / SideStore / Feather / ESign: "apps". Scarlet and others:
        // apps grouped in arrays under any key. A bare array also works.
        var list: [[String: Any]] = []
        let appKeys = ["apps", "Apps", "applications", "items", "data"]
        for k in appKeys { if let a = root[k] as? [[String: Any]] { list = a; break } }
        if list.isEmpty {
            for (k, v) in root where k != "news" && k != "featuredApps" {
                if let a = v as? [[String: Any]] { list += a }
                if let d = v as? [String: Any], let a = d["apps"] as? [[String: Any]] { list += a }
            }
        }
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
        var seen = Set<String>()
        return list.compactMap { a -> RepoApp? in
            let latest = (a["versions"] as? [[String: Any]])?.first
            let dlKeys = ["downloadURL", "downloadUrl", "download_url", "down", "download", "ipa", "ipaURL", "ipa_url", "link", "url"]
            var dl: URL? = nil
            for k in dlKeys where dl == nil { dl = url(latest?[k]) ?? url(a[k]) }
            guard let dl else { return nil }
            let name = str(a, "name", "title") ?? "App"
            let app = RepoApp(
                name: name,
                bundleID: str(a, "bundleIdentifier", "bundleID", "bundleId", "bundle", "identifier", "bundle_id") ?? name,
                developer: str(a, "developerName", "developer", "dev", "author") ?? "",
                subtitle: str(a, "subtitle") ?? "",
                description: str(a, "localizedDescription", "description", "desc", "subtitle") ?? "",
                version: (latest.flatMap { str($0, "version") }) ?? str(a, "version") ?? "",
                iconURL: url(a["iconURL"]) ?? url(a["icon"]) ?? url(a["iconUrl"]) ?? url(a["image"]) ?? url(a["icon_url"]),
                downloadURL: dl,
                size: int(latest?["size"]) ?? int(a["size"]) ?? int(a["fileSize"]),
                date: (latest.flatMap { str($0, "date") }) ?? str(a, "versionDate", "date", "updated"),
                screenshots: ScreenshotPolicy.sourceScreenshots(a, latest: latest, base: base)
            )
            return app
        }.filter { seen.insert($0.id).inserted }
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
    @ObservedObject private var installedApps = AppsStore.shared
    @State private var adding = false
    @State private var sharingURL: URL?
    @State private var input = ""
    @State private var finding = false

    var body: some View {
        NavigationStack {
            List {
                if store.sources.isEmpty {
                    Text(tr("Add a source link (AltStore, SideStore or Feather format) to browse its apps.",
                            "ضيف رابط سورس (بصيغة AltStore أو SideStore أو Feather) لتتصفّح تطبيقاته."))
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                if !store.availableUpdates().isEmpty || store.updatingAll {
                    Button {
                        Task { await store.updateAll() }
                    } label: {
                        Label(store.updatingAll ? tr("Updating apps…", "عم يحدّث التطبيقات…") : tr("Update All", "تحديث الكل"),
                              systemImage: "arrow.down.circle")
                    }
                    .disabled(store.updatingAll || AppsStore.shared.busy != nil)
                    .listRowBackground(Color.clear)
                }
                ForEach(store.visibleSources) { s in
                    NavigationLink { SourceDetailView(source: s) } label: { SourceRow(source: s, loading: store.loading.contains(s.url)) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .leading) {
                            Button { store.hiddenURLs.insert(s.url) } label: {
                                Label(tr("Hide", "إخفاء"), systemImage: "eye.slash")
                            }.tint(.orange)
                            SourceURLButtons(stored: s.url, sharing: $sharingURL).tint(.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            SourceURLButtons(stored: s.url, sharing: $sharingURL).tint(.blue)
                        }
                        .contextMenu {
                            SourceURLButtons(stored: s.url, sharing: $sharingURL)
                            Button { store.hiddenURLs.insert(s.url) } label: {
                                Label(tr("Hide source", "إخفاء السورس"), systemImage: "eye.slash")
                            }
                        }
                }
                .onMove { store.moveVisible(from: $0, to: $1) }
                .onDelete { offsets in
                    let urls = Set(offsets.map { store.visibleSources[$0].url })
                    store.sources.removeAll { urls.contains($0.url) }
                }
                if !store.hiddenSources.isEmpty {
                    Section(tr("Hidden Sources", "السورسات المخفية")) {
                        ForEach(store.hiddenSources) { source in
                            HStack {
                                Text(source.name)
                                Spacer()
                                Button {
                                    store.hiddenURLs.remove(source.url)
                                    Task { await store.refresh(source.url) }
                                } label: {
                                    Label(tr("Unhide", "إظهار"), systemImage: "eye")
                                }
                                .buttonStyle(.borderless)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await store.refreshAll() }
            .navigationTitle(tr("Sources", "السورسات"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { input = UIPasteboard.general.string ?? ""; adding = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { finding = true } label: { Image(systemName: "sparkle.magnifyingglass") }
                }
            }
            .sheet(isPresented: $finding) { DiscoveryView() }
            .sheet(item: Binding(get: { sharingURL.map { SharedSourceURL(url: $0) } }, set: { if $0 == nil { sharingURL = nil } })) { SourceShareSheet(url: $0.url).presentationDetents([.medium, .large]) }
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
    @AppStorage(MirsaTheme.key) private var theme = MirsaTheme.liquid.rawValue
    var body: some View {
        let tint = Color(hex: source.tint) ?? Color(red: 0.45, green: 0.38, blue: 0.95)
        HStack(spacing: 14) {
            if theme == MirsaTheme.liquid.rawValue {
                RemoteIcon(url: source.iconURL.flatMap(URL.init(string:)), size: 36, corner: 9)
                    .frame(width: 58, height: 58)
                    .appsGlass(cornerRadius: 18)
            } else {
                RemoteIcon(url: source.iconURL.flatMap(URL.init(string:)), size: 48, corner: 24)
            }
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
                Text("\(source.appCount)").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).frame(minWidth: 36, minHeight: 36)
                    .background(.white.opacity(0.2), in: Capsule())
            }
        }
        .padding(16)
        .modifier(SourceRowBackground(liquid: theme == MirsaTheme.liquid.rawValue, tint: tint))
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
        Task { await AppsStore.shared.installFromURL(app.downloadURL, location: target, appID: app.bundleID) }
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
                    AppScreenshotGallery(app: app)
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


private struct SourceRowBackground: ViewModifier {
    let liquid: Bool
    let tint: Color
    @ViewBuilder
    func body(content: Content) -> some View {
        if liquid {
            content.appsGlass(cornerRadius: 30, tint: tint)
        } else {
            content.background(tint.opacity(0.85), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}
