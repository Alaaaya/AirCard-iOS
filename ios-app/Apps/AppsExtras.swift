import Foundation
import SwiftUI
import Network
import AppIntents
import UserNotifications
import UIKit

/// Bilingual helper for the extras below.
@inline(__always) func tr(_ en: String, _ ar: String) -> String { L.isArabic ? ar : en }

// MARK: - Install from a link + expiry reminders

extension AppsStore {
    /// Downloads an IPA and imports it. When `location` is given (or the app is
    /// already managed) it installs straight away; otherwise the usual
    /// Container / Real App choice sheet appears.
    @discardableResult
    func installFromURL(_ url: URL, location: AppLocation? = nil, vm: AppViewModel? = nil) async -> Bool {
        let vm = vm ?? AppViewModel.shared
        busy = tr("Downloading…", "عم ينزّل…")
        let file: URL
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                busy = nil; error = tr("Download failed (\(h.statusCode))", "فشل التنزيل (\(h.statusCode))"); return false
            }
            file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString).ipa")
            try FileManager.default.moveItem(at: tmp, to: file)
        } catch {
            busy = nil; self.error = error.localizedDescription; return false
        }
        busy = nil
        defer { try? FileManager.default.removeItem(at: file) }
        await importIPA(from: file)
        guard let p = pending else { return false }
        let target = location ?? apps.first(where: { $0.id == p.bundleID })?.location
        guard let target else { return true }   // user picks in the sheet
        await commitPending(to: target, vm: vm)
        scheduleExpiryReminders()
        return error == nil
    }

    /// One local notification per real app (and Mirsa itself), a day before it expires.
    func scheduleExpiryReminders() {
        let center = UNUserNotificationCenter.current()
        var items: [(String, String, Date)] = realApps.compactMap { a in a.expires.map { (a.id, a.name, $0) } }
        if let own = ownExpiry { items.append(("mirsa.self", "Mirsa", own)) }
        center.getPendingNotificationRequests { reqs in
            center.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier).filter { $0.hasPrefix("mirsa.expiry.") })
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                guard granted else { return }
                for (id, name, exp) in items {
                    let fire = exp.addingTimeInterval(-86_400)
                    guard fire > Date() else { continue }
                    let c = UNMutableNotificationContent()
                    c.title = "Mirsa"
                    c.body = tr("\(name) expires tomorrow. Open Mirsa to refresh it.",
                                "\(name) بتنتهي صلاحيته بكرا. افتح Mirsa وجدّده.")
                    c.sound = .default
                    let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                    center.add(UNNotificationRequest(identifier: "mirsa.expiry.\(id)", content: c,
                                                     trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
                }
            }
        }
    }
}

// MARK: - GitHub auto-updates

struct GitHubSource: Codable, Identifiable, Hashable {
    var repo: String            // owner/name
    var lastTag: String?
    var appID: String?          // bundle id installed from it
    var id: String { repo }
}

@MainActor
final class GitHubWatcher: ObservableObject {
    static let shared = GitHubWatcher()
    @Published var sources: [GitHubSource] = [] { didSet { persist() } }
    @Published var checking = false
    @Published var lastResult: String?
    @Published var autoInstall: Bool = UserDefaults.standard.object(forKey: "gh.autoInstall") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoInstall, forKey: "gh.autoInstall") }
    }

    private init() {
        if let d = UserDefaults.standard.data(forKey: "gh.sources"),
           let s = try? JSONDecoder().decode([GitHubSource].self, from: d) { sources = s }
    }
    private func persist() {
        if let d = try? JSONEncoder().encode(sources) { UserDefaults.standard.set(d, forKey: "gh.sources") }
    }

    /// Accepts "owner/repo" or any github.com URL of the repo.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "www.", "github.com/"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        if s.lowercased().hasPrefix("github.com/") { s.removeFirst("github.com/".count) }
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1].replacingOccurrences(of: ".git", with: ""))"
    }

    func add(_ raw: String) -> Bool {
        guard let r = Self.normalize(raw), !sources.contains(where: { $0.repo.lowercased() == r.lowercased() }) else { return false }
        sources.append(GitHubSource(repo: r))
        return true
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let assets: [Asset]
    }

    private func latest(_ repo: String) async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Mirsa", forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: req)
        if let h = r as? HTTPURLResponse, h.statusCode != 200 {
            throw NSError(domain: "GitHub", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub \(h.statusCode)"])
        }
        return try JSONDecoder().decode(Release.self, from: d)
    }

    /// Checks every source; installs new releases when `install` is true.
    /// Returns how many updates were found.
    @discardableResult
    func checkAll(install: Bool) async -> Int {
        guard !checking else { return 0 }
        checking = true; defer { checking = false }
        var found = 0
        let store = AppsStore.shared
        for i in sources.indices {
            let s = sources[i]
            guard let rel = try? await latest(s.repo),
                  let asset = rel.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") }) else { continue }
            guard rel.tag_name != s.lastTag else { continue }
            found += 1
            guard install else { continue }
            let known = s.appID.flatMap { id in store.apps.first(where: { $0.id == id })?.location }
            if s.lastTag == nil && known == nil {
                // First time: let the user pick Container or Real App.
                await store.installFromURL(asset.browser_download_url)
                sources[i].lastTag = rel.tag_name
                sources[i].appID = store.pending?.bundleID
                break   // one choice sheet at a time
            }
            let pendingBID = { () -> String? in store.pending?.bundleID }
            if await store.installFromURL(asset.browser_download_url, location: known) {
                sources[i].lastTag = rel.tag_name
                if sources[i].appID == nil { sources[i].appID = pendingBID() ?? store.apps.last?.id }
            }
        }
        lastResult = found == 0 ? tr("Everything is up to date", "كلشي محدّث")
                                : tr("\(found) update(s) found", "في \(found) تحديث")
        return found
    }
}

// MARK: - Upload from a computer on the same Wi-Fi

@MainActor
final class WebUploadServer: ObservableObject {
    static let shared = WebUploadServer()
    static let port: UInt16 = 8080
    @Published var running = false
    @Published var received: String?
    private var listener: NWListener?

    var address: String? { Self.wifiIPv4().map { "http://\($0):\(Self.port)" } }

    func toggle() { running ? stop() : start() }

    func start() {
        guard listener == nil, let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!) else { return }
        l.newConnectionHandler = { conn in
            conn.start(queue: .global())
            UploadConnection(conn).run()
        }
        l.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                switch st {
                case .ready: self?.running = true
                case .failed, .cancelled: self?.running = false; self?.listener = nil
                default: break
                }
            }
        }
        l.start(queue: .global())
        listener = l
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        listener?.cancel(); listener = nil; running = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    nonisolated static func wifiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let i = cur.pointee
            if i.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: i.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(i.ifa_addr, socklen_t(i.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            p = i.ifa_next
        }
        return nil
    }

    static let page = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Mirsa</title><style>
    body{margin:0;min-height:100vh;display:grid;place-items:center;font-family:-apple-system,system-ui,sans-serif;color:#fff;
    background:radial-gradient(circle at 20% 20%,#5b3cc4,transparent 50%),radial-gradient(circle at 80% 80%,#1f6fd1,transparent 50%),#0b0b14}
    .c{width:min(92vw,460px);padding:32px;border-radius:28px;background:rgba(255,255,255,.08);backdrop-filter:blur(20px);text-align:center}
    h1{margin:0 0 6px;font-size:30px}p{opacity:.7}
    #d{margin-top:20px;padding:36px 16px;border:2px dashed rgba(255,255,255,.35);border-radius:20px;cursor:pointer}
    #d.o{background:rgba(255,255,255,.1)}progress{width:100%;margin-top:16px;display:none}
    </style></head><body><div class="c"><h1>Mirsa</h1><p>Drop an .ipa to install it on your iPhone</p>
    <div id="d">Drop IPA here or click</div><input id="f" type="file" accept=".ipa" hidden><progress id="p" max="100"></progress><p id="s"></p></div>
    <script>
    const d=document.getElementById('d'),f=document.getElementById('f'),p=document.getElementById('p'),s=document.getElementById('s');
    d.onclick=()=>f.click();f.onchange=()=>f.files[0]&&up(f.files[0]);
    d.ondragover=e=>{e.preventDefault();d.classList.add('o')};d.ondragleave=()=>d.classList.remove('o');
    d.ondrop=e=>{e.preventDefault();d.classList.remove('o');e.dataTransfer.files[0]&&up(e.dataTransfer.files[0])};
    function up(file){if(!file.name.toLowerCase().endsWith('.ipa')){s.textContent='Only .ipa files';return}
    const x=new XMLHttpRequest();x.open('POST','/upload?name='+encodeURIComponent(file.name));
    p.style.display='block';x.upload.onprogress=e=>{p.value=e.loaded/e.total*100};
    x.onload=()=>{s.textContent=x.status==200?'Sent. Continue on your iPhone.':'Failed ('+x.status+')'};
    x.onerror=()=>s.textContent='Connection lost';x.send(file)}
    </script></body></html>
    """
}

/// One HTTP connection: GET / serves the page, POST /upload streams the body to disk.
private final class UploadConnection {
    let conn: NWConnection
    var header = Data()
    var file: FileHandle?
    var fileURL: URL?
    var remaining = 0
    init(_ c: NWConnection) { conn = c }

    func run() { readHeader() }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, done, err in
            if let data { header.append(data) }
            if let r = header.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: header[..<r.lowerBound], as: UTF8.self)
                let body = header[r.upperBound...]
                handle(head: head, firstBody: Data(body))
            } else if done || err != nil || header.count > 65_536 {
                conn.cancel()
            } else { readHeader() }
        }
    }

    private func handle(head: String, firstBody: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let req = lines.first?.split(separator: " ") ?? []
        guard req.count >= 2 else { return send(400, "bad request") }
        let method = String(req[0]), path = String(req[1])
        if method == "GET" { return send(200, WebUploadServer.page, type: "text/html; charset=utf-8") }
        guard method == "POST", path.hasPrefix("/upload") else { return send(404, "not found") }
        let len = lines.first(where: { $0.lowercased().hasPrefix("content-length:") })
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        guard len > 0 else { return send(411, "length required") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("web-\(UUID().uuidString).ipa")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else { return send(500, "disk") }
        file = fh; fileURL = url; remaining = len
        write(firstBody)
    }

    private func write(_ d: Data) {
        let chunk = d.prefix(remaining)
        if !chunk.isEmpty { file?.write(chunk); remaining -= chunk.count }
        if remaining <= 0 { return finish() }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, err in
            if let data { write(data) } else if done || err != nil { abort() }
        }
    }

    private func abort() {
        try? file?.close(); if let u = fileURL { try? FileManager.default.removeItem(at: u) }
        conn.cancel()
    }

    private func finish() {
        try? file?.close()
        send(200, "ok")
        guard let u = fileURL else { return }
        Task { @MainActor in
            WebUploadServer.shared.received = u.lastPathComponent
            await AppsStore.shared.importIPA(from: u)
            try? FileManager.default.removeItem(at: u)
        }
    }

    private func send(_ code: Int, _ body: String, type: String = "text/plain; charset=utf-8") {
        let b = Data(body.utf8)
        let status = code == 200 ? "OK" : "Error"
        var h = "HTTP/1.1 \(code) \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(b.count)\r\nConnection: close\r\n\r\n"
        if code != 200 { h = h.replacingOccurrences(of: "Error", with: "Error") }
        conn.send(content: Data(h.utf8) + b, completion: .contentProcessed { [conn] _ in conn.cancel() })
    }
}

// MARK: - Shortcuts: install from a link

struct InstallFromLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Install IPA from Link"
    static var description = IntentDescription("Downloads an IPA from a link, signs it and installs it with Mirsa.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "IPA link") var link: URL
    @Parameter(title: "Install as real app", default: true) var asReal: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppsStore.shared
        guard await store.ensureSession() else {
            return .result(dialog: IntentDialog(stringLiteral: L.t("err.notSignedIn")))
        }
        let ok = await store.installFromURL(link, location: asReal ? .real : .container)
        if !ok, let e = store.error { store.error = nil; return .result(dialog: IntentDialog(stringLiteral: e)) }
        return .result(dialog: IntentDialog(stringLiteral: tr("Installed", "تم التثبيت")))
    }
}

// MARK: - Settings views

struct ExpiryListView: View {
    @ObservedObject var store: AppsStore
    var body: some View {
        let own = store.ownExpiry
        ForEach(store.realApps) { a in row(a.name, a.expires) }
        row("Mirsa", own)
        Button { store.scheduleExpiryReminders() } label: {
            Label(tr("Remind me a day before", "نبّهني قبل بيوم"), systemImage: "bell.badge")
        }
    }

    private func row(_ name: String, _ exp: Date?) -> some View {
        let days = exp.map { max(0, Int(ceil($0.timeIntervalSinceNow / 86_400))) }
        return HStack {
            Text(name)
            Spacer()
            if let days {
                Text(tr("\(days) days", "\(days) يوم"))
                    .font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(days <= 2 ? .red : (days <= 4 ? .orange : .green))
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }
}

struct GitHubSourcesView: View {
    @ObservedObject var gh = GitHubWatcher.shared
    @State private var input = ""
    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("owner/repo", text: $input)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(tr("Add", "أضف")) { if gh.add(input) { input = "" } }
                        .disabled(GitHubWatcher.normalize(input) == nil)
                }
            } footer: {
                Text(tr("Mirsa installs the .ipa from each repo's latest release, and updates it when a new one comes out.",
                        "Mirsa بيثبّت ملف ‎.ipa من آخر إصدار بكل مستودع، وبيحدّثه أول ما ينزل إصدار جديد."))
            }
            if !gh.sources.isEmpty {
                Section(tr("Repositories", "المستودعات")) {
                    ForEach(gh.sources) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.repo).font(.body.weight(.semibold))
                            Text(s.lastTag ?? tr("Not installed yet", "لسا ما تثبّت")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { gh.sources.remove(atOffsets: $0) }
                }
            }
            Section {
                Toggle(tr("Install updates automatically", "ثبّت التحديثات تلقائياً"), isOn: $gh.autoInstall)
                Button {
                    Task { await gh.checkAll(install: true) }
                } label: {
                    HStack {
                        Label(tr("Check now", "افحص هلّق"), systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if gh.checking { ProgressView() }
                    }
                }
                .disabled(gh.checking || gh.sources.isEmpty)
                if let r = gh.lastResult { Text(r).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .mirsaScreen()
        .navigationTitle(tr("GitHub Updates", "تحديثات GitHub"))
    }
}

struct WebUploadView: View {
    @ObservedObject var server = WebUploadServer.shared
    var body: some View {
        Form {
            Section {
                Toggle(tr("Receive from computer", "استقبل من الكمبيوتر"), isOn: Binding(
                    get: { server.running }, set: { $0 ? server.start() : server.stop() }))
                if server.running {
                    if let a = server.address {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tr("Open this on your computer:", "افتح هاد بمتصفح الكمبيوتر:")).font(.footnote).foregroundStyle(.secondary)
                            Text(a).font(.title3.weight(.bold).monospaced()).textSelection(.enabled)
                        }
                    } else {
                        Text(tr("Connect to Wi-Fi first", "اتصل بالواي فاي أولاً")).foregroundStyle(.orange)
                    }
                }
                if let r = server.received {
                    Label(tr("Received \(r)", "وصل \(r)"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } footer: {
                Text(tr("Keep Mirsa open. Drop an .ipa on the page and choose Container or Real App here.",
                        "خلّي Mirsa مفتوح. اسحب ملف ‎.ipa عالصفحة، وبعدين اختار Container أو تطبيق حقيقي من هون."))
            }
        }
        .mirsaScreen()
        .navigationTitle(tr("Upload from Computer", "رفع من الكمبيوتر"))
    }
}

// MARK: - Mirsa updates itself

/// Checks GitHub Releases of Mirsa's own repo on launch. When a newer build is
/// out it shows a sheet; "Update now" downloads it and installs it over this
/// copy with the user's Apple ID (iOS closes Mirsa for a moment while it
/// installs; data stays because the bundle id is the same).
@MainActor
final class MirsaUpdater: ObservableObject {
    static let shared = MirsaUpdater()
    static let repo = "Alaaaya/AirCard-iOS"

    struct Release: Identifiable, Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let name: String?
        let body: String?
        let assets: [Asset]
        var id: String { tag_name }
        var build: Int { Int(tag_name.filter(\.isNumber)) ?? 0 }
        var ipa: URL? { (assets.first(where: { $0.name == "Mirsa.ipa" }) ?? assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") && !$0.name.contains("Setup") }))?.browser_download_url }
    }

    @Published var available: Release?
    @Published var installing = false

    static var currentBuild: Int {
        Int((Bundle.main.object(forInfoDictionaryKey: "MirsaBuild") as? String ?? "").filter(\.isNumber)) ?? 0
    }
    private var skipped: String? {
        get { UserDefaults.standard.string(forKey: "mirsa.update.skipped") }
        set { UserDefaults.standard.set(newValue, forKey: "mirsa.update.skipped") }
    }

    func check(force: Bool = false) async {
        guard !AppsStore.isSetupMode, available == nil else { return }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Mirsa", forHTTPHeaderField: "User-Agent")
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200,
              let rel = try? JSONDecoder().decode(Release.self, from: d),
              rel.ipa != nil, rel.build > Self.currentBuild else { return }
        if !force, rel.tag_name == skipped { return }
        available = rel
    }

    func later(_ rel: Release) { skipped = rel.tag_name; available = nil }

    func install(_ rel: Release, vm: AppViewModel) async {
        guard let url = rel.ipa else { return }
        let store = AppsStore.shared
        installing = true; defer { installing = false }
        available = nil
        store.busy = tr("Downloading update…", "عم ينزّل التحديث…")
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("upd-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                throw NSError(domain: "Mirsa", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "Download failed (\(h.statusCode))"])
            }
            let ipa = work.appendingPathComponent("u.ipa")
            try fm.moveItem(at: tmp, to: ipa)
            let out = work.appendingPathComponent("x", isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            let ok = await Task.detached { SideloadService.unzip(ipa.path, to: out.path) }.value
            let payload = out.appendingPathComponent("Payload", isDirectory: true)
            guard ok, let app = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
                    .first(where: { $0.pathExtension == "app" }) else {
                throw NSError(domain: "Mirsa", code: 1, userInfo: [NSLocalizedDescriptionKey: "The update file is not a valid IPA"])
            }
            store.busy = nil
            skipped = nil
            await store.installSelf(vm: vm, from: app)
        } catch {
            store.busy = nil
            store.error = error.localizedDescription
        }
    }
}

struct MirsaUpdateSheet: View {
    let release: MirsaUpdater.Release
    @ObservedObject var updater: MirsaUpdater
    let onUpdate: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 40)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("New version available", "في نسخة جديدة")).font(.title3.bold())
                    Text(tr("Build \(release.build)", "النسخة \(release.build)")).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("What's new", "شو الجديد")).font(.headline)
                    Text((release.body?.isEmpty == false ? release.body! : (release.name ?? release.tag_name)))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06)))
            Text(tr("Mirsa closes for a moment while it installs, then it's updated. Wi-Fi and LocalDevVPN need to be on.",
                    "Mirsa رح يسكّر لحظة وهو عم يتثبّت، وبعدين بيكون محدّث. لازم يكون الواي فاي و LocalDevVPN شغّالين."))
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action: onUpdate) {
                Text(tr("Update now", "حدّث هلّق")).font(.headline).frame(maxWidth: .infinity).padding()
                    .background(RoundedRectangle(cornerRadius: 16).fill(.green.opacity(0.8)))
                    .foregroundStyle(.white)
            }
            if let ipa = release.ipa {
                Button { openURL(ipa) } label: {
                    Label(tr("Download IPA manually", "نزّل الـ IPA يدوياً"), systemImage: "arrow.down.circle")
                }.font(.subheadline)
            }
            Button(tr("Later", "لاحقاً")) { updater.later(release) }
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
