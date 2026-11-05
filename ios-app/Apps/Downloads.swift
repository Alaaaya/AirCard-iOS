import SwiftUI
import Network
import UIKit

// MARK: - Downloads library: every imported IPA is kept (last 2 versions per app)

struct DownloadItem: Codable, Identifiable, Hashable {
    var id: String { bundleID + "/" + version }
    let bundleID: String
    let name: String
    let version: String
    let size: Int64
    let date: Date
}

@MainActor
final class DownloadsLibrary: ObservableObject {
    static let shared = DownloadsLibrary()
    static let keepPerApp = 2
    @Published private(set) var items: [DownloadItem] = []

    static var root: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static func safe(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }
    static func folder(_ bid: String, _ version: String) -> URL {
        root.appendingPathComponent(safe(bid), isDirectory: true).appendingPathComponent(safe(version), isDirectory: true)
    }
    static func ipaURL(_ i: DownloadItem) -> URL { folder(i.bundleID, i.version).appendingPathComponent("\(safe(i.name))-\(safe(i.version)).ipa") }
    static func iconURL(_ i: DownloadItem) -> URL { folder(i.bundleID, i.version).appendingPathComponent("icon.png") }

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        var out: [DownloadItem] = []
        for app in (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? [] {
            for ver in (try? fm.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)) ?? [] {
                if let d = try? Data(contentsOf: ver.appendingPathComponent("meta.json")),
                   let i = try? JSONDecoder().decode(DownloadItem.self, from: d),
                   fm.fileExists(atPath: Self.ipaURL(i).path) {
                    out.append(i)
                }
            }
        }
        items = out.sorted { $0.date > $1.date }
    }

    /// Keep a copy of an imported IPA. Ignored when the file already lives in the library.
    func add(ipa: URL, bundleID: String, name: String, version: String, size: Int64, icon: UIImage?) {
        let fm = FileManager.default
        if ipa.standardizedFileURL.path.hasPrefix(Self.root.standardizedFileURL.path) { return }
        let item = DownloadItem(bundleID: bundleID, name: name, version: version, size: size, date: Date())
        let dir = Self.folder(bundleID, version)
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: ipa, to: Self.ipaURL(item))
            if let png = icon?.pngData() { try? png.write(to: Self.iconURL(item)) }
            try JSONEncoder().encode(item).write(to: dir.appendingPathComponent("meta.json"))
        } catch {
            try? fm.removeItem(at: dir)
            return
        }
        // Prune: newest `keepPerApp` versions of this app.
        reload()
        let mine = items.filter { $0.bundleID == bundleID }.sorted { $0.date > $1.date }
        for old in mine.dropFirst(Self.keepPerApp) { try? fm.removeItem(at: Self.folder(old.bundleID, old.version)) }
        reload()
    }

    func remove(_ i: DownloadItem) {
        try? FileManager.default.removeItem(at: Self.folder(i.bundleID, i.version))
        reload()
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

struct DownloadsList: View {
    @ObservedObject var lib = DownloadsLibrary.shared
    @ObservedObject var store: AppsStore

    var body: some View {
        if lib.items.isEmpty {
            ContentUnavailableView {
                Label(tr("No downloads yet", "ما في تنزيلات لسا"), systemImage: "arrow.down.circle").foregroundStyle(.white)
            } description: {
                Text(tr("Every IPA you install from a source or a file is kept here, the last two versions of each app.",
                        "كل IPA بتنصّبه من سورس أو ملف بينحفظ هون، آخر نسختين من كل تطبيق."))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
            .appsGlass(cornerRadius: 28)
        } else {
            VStack(spacing: 10) {
                ForEach(lib.items) { i in row(i) }
                Text(tr("Total ", "المجموع ") + ByteCountFormatter.string(fromByteCount: lib.totalSize, countStyle: .file))
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func row(_ i: DownloadItem) -> some View {
        let installed = store.apps.first { $0.id == i.bundleID }
        return HStack(spacing: 12) {
            Group {
                if let img = UIImage(contentsOfFile: DownloadsLibrary.iconURL(i).path) {
                    Image(uiImage: img).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().scaledToFit().padding(10).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(i.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                Text("\(i.version) · " + ByteCountFormatter.string(fromByteCount: i.size, countStyle: .file)
                     + " · " + i.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                if let installed {
                    Text(installed.version == i.version ? tr("Installed", "منصّب") : tr("Installed: \(installed.version)", "المنصّب: \(installed.version)"))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.green.opacity(0.85))
                }
            }
            Spacer()
            Button { install(i) } label: {
                Text(installed?.version == i.version ? tr("Reinstall", "أعد") : tr("Install", "نصّب"))
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .appsGlassCapsule(tint: Color(red: 0.45, green: 0.4, blue: 1))
        }
        .padding(12)
        .appsGlass(cornerRadius: 20)
        .contextMenu {
            Button { install(i) } label: { Label(tr("Install", "نصّب"), systemImage: "arrow.down.app") }
            ShareLink(item: DownloadsLibrary.ipaURL(i)) { Label(tr("Share IPA", "شارك الـIPA"), systemImage: "square.and.arrow.up") }
            Divider()
            Button(role: .destructive) { lib.remove(i) } label: { Label(tr("Delete", "حذف"), systemImage: "trash") }
        }
    }

    private func install(_ i: DownloadItem) {
        Task { await store.importIPA(from: DownloadsLibrary.ipaURL(i)) }
    }
}

// MARK: - Home Screen shortcut for a Container app (web clip profile, like LiveContainer)

@MainActor
enum HomeShortcut {
    private static var listener: NWListener?
    private static var bgTask: UIBackgroundTaskIdentifier = .invalid

    static func add(_ app: ManagedApp) -> String? {
        guard let profile = profileData(app) else { return tr("Couldn't build the shortcut.", "ما قدرت اعمل الاختصار.") }
        listener?.cancel(); listener = nil
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { return tr("Couldn't start the local server.", "ما قدرت شغّل السيرفر المحلي.") }
        l.newConnectionHandler = { conn in serve(conn, profile: profile) }
        l.stateUpdateHandler = { st in
            guard case .ready = st, let port = l.port?.rawValue else { return }
            Task { @MainActor in
                if let u = URL(string: "http://127.0.0.1:\(port)/\(app.id).mobileconfig") { UIApplication.shared.open(u) }
            }
        }
        bgTask = UIApplication.shared.beginBackgroundTask { endBG() }
        l.start(queue: .global())
        listener = l
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            listener?.cancel(); listener = nil; endBG()
        }
        return nil
    }

    private static func endBG() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    nonisolated private static func serve(_ conn: NWConnection, profile: Data) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-apple-aspen-config\r\nContent-Length: \(profile.count)\r\nConnection: close\r\n\r\n"
            var body = Data(head.utf8); body.append(profile)
            conn.send(content: body, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private static func profileData(_ app: ManagedApp) -> Data? {
        var iconData: Data?
        if let img = UIImage(contentsOfFile: AppsStore.iconURL(app.id).path) {
            let size = CGSize(width: 180, height: 180)
            let r = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            iconData = r.pngData { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        }
        var clip: [String: Any] = [
            "PayloadType": "com.apple.webClip.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.alaa.mirsa.webclip.\(app.id)",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": app.name,
            "Label": app.name,
            "URL": "mirsa://launch?bundle=\(app.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? app.id)",
            "IsRemovable": true,
            "FullScreen": true,
            "IgnoreManifestScope": true,
        ]
        if let iconData { clip["Icon"] = iconData; clip["Precomposed"] = true }
        let root: [String: Any] = [
            "PayloadContent": [clip],
            "PayloadDisplayName": "\(app.name) · Mirsa",
            "PayloadDescription": tr("Opens \(app.name) in Mirsa's container.", "بيفتح \(app.name) بكونتينر Mirsa."),
            "PayloadIdentifier": "com.alaa.mirsa.shortcut.\(app.id)",
            "PayloadType": "Configuration",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
            "PayloadRemovalDisallowed": false,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    /// mirsa://launch?bundle=<id>
    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "mirsa", url.host == "launch",
              let bid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "bundle" })?.value
        else { return false }
        let store = AppsStore.shared
        guard let app = store.apps.first(where: { $0.id == bid }) else {
            store.error = tr("That app isn't in Mirsa anymore.", "هالتطبيق ما عاد موجود بـMirsa.")
            return true
        }
        store.launch(app)
        return true
    }
}
