import SwiftUI

// MARK: - Device tools (over the pairing tunnel): battery, storage,
// provisioning profiles, crash logs and the Media folder.

@MainActor
final class DeviceToolsModel: ObservableObject {
    @Published var loading = false
    @Published var error: String?

    func run(_ kind: String, arg: String = "", outPath: String = "") async -> Any? {
        loading = true
        defer { loading = false }
        do {
            return try await Task.detached { try SideloadService.devTool(kind, arg: arg, outPath: outPath) }.value
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    static var exportsDir: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
private func num(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

private extension View {
    func toolAlert(_ m: DeviceToolsModel) -> some View {
        alert(tr("Device", "الجهاز"), isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
            Button("OK") { m.error = nil }
        } message: { Text(m.error ?? "") }
    }
}

struct DeviceToolsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { BatteryView() } label: { Label(tr("Battery health", "صحة البطارية"), systemImage: "battery.75percent") }
                    NavigationLink { StorageView() } label: { Label(tr("Storage by app", "المساحة لكل تطبيق"), systemImage: "internaldrive") }
                    NavigationLink { ProfilesView() } label: { Label(tr("Provisioning profiles", "البروفايلات"), systemImage: "checkmark.seal") }
                    NavigationLink { CrashLogsView() } label: { Label(tr("Crash logs", "سجلات الكراش"), systemImage: "exclamationmark.triangle") }
                    NavigationLink { MediaFilesView(path: "/") } label: { Label(tr("Media files", "ملفات الوسائط"), systemImage: "folder") }
                } footer: {
                    Text(tr("These need Wi-Fi, LocalDevVPN and Mirsa's pairing.",
                            "هدول بدهم واي فاي وLocalDevVPN والاقتران تبع Mirsa."))
                }
            }
            .navigationTitle(tr("Device", "الجهاز"))
            .mirsaScreen()
        }
    }
}

// MARK: Battery

struct BatteryView: View {
    @StateObject private var m = DeviceToolsModel()
    @State private var rows: [(String, String)] = []

    var body: some View {
        Form {
            if m.loading { ProgressView() }
            ForEach(rows, id: \.0) { r in
                HStack { Text(r.0); Spacer(); Text(r.1).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(tr("Battery health", "صحة البطارية"))
        .task { await load() }
        .refreshable { await load() }
        .toolAlert(m)
        .mirsaScreen()
    }

    private func load() async {
        guard let o = await m.run("battery") as? [String: Any] else { return }
        // IORegistry answers either the entry itself or wrapped in "IORegistry".
        var io = (o["ioreg"] as? [String: Any]) ?? [:]
        if let inner = io["IORegistry"] as? [String: Any] { io = inner }
        let gas = (o["gasgauge"] as? [String: Any]) ?? [:]
        let design = num(io["DesignCapacity"]) ?? num(gas["DesignCapacity"])
        let full = num(io["AppleRawMaxCapacity"]) ?? num(io["NominalChargeCapacity"]) ?? num(gas["FullChargeCapacity"])
        var r: [(String, String)] = []
        if let d = design, let f = full, d > 0 {
            r.append((tr("Health", "الصحة"), String(format: "%.0f%%", min(100, f / d * 100))))
        }
        if let f = full { r.append((tr("Full charge capacity", "السعة الكاملة"), String(format: "%.0f mAh", f))) }
        if let d = design { r.append((tr("Design capacity", "السعة الأصلية"), String(format: "%.0f mAh", d))) }
        if let c = num(io["CycleCount"]) ?? num(gas["CycleCount"]) { r.append((tr("Cycles", "الدورات"), String(format: "%.0f", c))) }
        if let t = num(io["Temperature"]) { r.append((tr("Temperature", "الحرارة"), String(format: "%.1f °C", t / 100))) }
        if let p = num(io["CurrentCapacity"]) { r.append((tr("Charge", "الشحن"), String(format: "%.0f%%", p))) }
        if let v = num(io["Voltage"]) { r.append((tr("Voltage", "الفولت"), String(format: "%.2f V", v / 1000))) }
        if let c = io["IsCharging"] as? Bool { r.append((tr("Charging", "عم يشحن"), c ? tr("Yes", "إي") : tr("No", "لأ"))) }
        if r.isEmpty { m.error = tr("iOS didn't return battery data.", "iOS ما رجّع معلومات البطارية.") }
        rows = r
    }
}

// MARK: Storage

struct StorageView: View {
    @StateObject private var m = DeviceToolsModel()
    struct Row: Identifiable { let id: String; let name: String; let app: Int64; let data: Int64 }
    @State private var rows: [Row] = []

    var body: some View {
        Form {
            if m.loading { ProgressView() }
            if !rows.isEmpty {
                Section(tr("Total: ", "المجموع: ") + bytes(rows.reduce(0) { $0 + $1.app + $1.data })) {
                    ForEach(rows) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(r.name).lineLimit(1); Spacer(); Text(bytes(r.app + r.data)).bold() }
                            Text(tr("App ", "التطبيق ") + bytes(r.app) + " · " + tr("Data ", "البيانات ") + bytes(r.data))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(tr("Storage by app", "المساحة لكل تطبيق"))
        .task { await load() }
        .refreshable { await load() }
        .toolAlert(m)
        .mirsaScreen()
    }

    private func load() async {
        guard let list = await m.run("storage") as? [[String: Any]] else { return }
        rows = list.compactMap { a in
            guard let id = a["CFBundleIdentifier"] as? String else { return nil }
            let name = (a["CFBundleDisplayName"] as? String) ?? (a["CFBundleName"] as? String) ?? id
            return Row(id: id, name: name, app: Int64(num(a["StaticDiskUsage"]) ?? 0), data: Int64(num(a["DynamicDiskUsage"]) ?? 0))
        }.sorted { $0.app + $0.data > $1.app + $1.data }
    }
}

// MARK: Profiles

struct ProfilesView: View {
    @StateObject private var m = DeviceToolsModel()
    struct P: Identifiable { let id: String; let name: String; let team: String; let expires: Date? }
    @State private var list: [P] = []

    var body: some View {
        Form {
            if m.loading { ProgressView() }
            let expired = list.filter { ($0.expires ?? .distantFuture) < Date() }
            if !expired.isEmpty {
                Section {
                    Button(role: .destructive) {
                        Task { for p in expired { _ = await m.run("profile_remove", arg: p.id) }; await load() }
                    } label: { Label(tr("Remove \(expired.count) expired", "احذف \(expired.count) منتهية"), systemImage: "trash") }
                }
            }
            Section {
                ForEach(list) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).lineLimit(1)
                        Text(p.team + " · " + expiryText(p.expires)).font(.caption)
                            .foregroundStyle((p.expires ?? .distantFuture) < Date() ? .red : .secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { _ = await m.run("profile_remove", arg: p.id); await load() }
                        } label: { Label(tr("Delete", "حذف"), systemImage: "trash") }
                    }
                }
            } footer: {
                Text(tr("Removing a profile stops the app that uses it from opening until it is renewed.",
                        "حذف البروفايل بيوقف التطبيق اللي بيستعمله لحد ما ينجدّد."))
            }
        }
        .navigationTitle(tr("Provisioning profiles", "البروفايلات"))
        .task { await load() }
        .refreshable { await load() }
        .toolAlert(m)
        .mirsaScreen()
    }

    private func expiryText(_ d: Date?) -> String {
        guard let d else { return "—" }
        let days = Int(ceil(d.timeIntervalSinceNow / 86_400))
        return days < 0 ? tr("Expired", "منتهي") : tr("\(days) days left", "باقي \(days) يوم")
    }

    private func load() async {
        guard let arr = await m.run("profiles") as? [[String: Any]] else { return }
        let iso = ISO8601DateFormatter()
        list = arr.compactMap { d in
            guard let id = d["uuid"] as? String else { return nil }
            return P(id: id, name: (d["name"] as? String) ?? (d["appIDName"] as? String) ?? id,
                     team: (d["team"] as? String) ?? "", expires: (d["expires"] as? String).flatMap(iso.date(from:)))
        }.sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
    }
}

// MARK: Crash logs

struct CrashLogsView: View {
    @StateObject private var m = DeviceToolsModel()
    @State private var names: [String] = []
    @State private var query = ""
    @State private var opened: CrashFile?
    struct CrashFile: Identifiable { let id = UUID(); let name: String; let url: URL; let text: String }

    var body: some View {
        let shown = (query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) })
        List {
            if m.loading { ProgressView() }
            ForEach(shown, id: \.self) { n in
                Button { Task { await open(n) } } label: { Text(n).font(.footnote).lineLimit(2) }
            }
        }
        .searchable(text: $query)
        .navigationTitle(tr("Crash logs", "سجلات الكراش"))
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $opened) { f in
            NavigationStack {
                ScrollView { Text(f.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding() }
                    .navigationTitle(f.name).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { ShareLink(item: f.url) } }
            }
        }
        .toolAlert(m)
        .mirsaScreen()
    }

    private func load() async {
        guard let arr = await m.run("crashes") as? [String] else { return }
        names = arr.filter { $0.hasSuffix(".ips") || $0.hasSuffix(".crash") || $0.hasSuffix(".log") }.sorted(by: >)
        if names.isEmpty { names = arr.sorted(by: >) }
    }

    private func open(_ name: String) async {
        let out = DeviceToolsModel.exportsDir.appendingPathComponent(name)
        guard await m.run("crash_pull", arg: name, outPath: out.path) != nil || FileManager.default.fileExists(atPath: out.path) else { return }
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? tr("Couldn't read the file.", "ما قدرت اقرأ الملف.")
        opened = CrashFile(name: name, url: out, text: text)
    }
}

// MARK: Media files (AFC, /var/mobile/Media)

struct MediaFilesView: View {
    let path: String
    @StateObject private var m = DeviceToolsModel()
    struct Entry: Identifiable { var id: String { path }; let name: String; let path: String; let dir: Bool; let size: Int64 }
    @State private var entries: [Entry] = []
    @State private var shareURL: URL?

    var body: some View {
        List {
            if m.loading { ProgressView() }
            ForEach(entries) { e in
                if e.dir {
                    NavigationLink { MediaFilesView(path: e.path) } label: { Label(e.name, systemImage: "folder") }
                } else {
                    Button { Task { await pull(e) } } label: {
                        HStack {
                            Label(e.name, systemImage: "doc").lineLimit(1)
                            Spacer()
                            Text(bytes(e.size)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { _ = await m.run("afc_remove", arg: e.path); await load() }
                        } label: { Label(tr("Delete", "حذف"), systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle(path == "/" ? tr("Media files", "ملفات الوسائط") : (path as NSString).lastPathComponent)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { if $0 == nil { shareURL = nil } })) { s in
            MirsaShareSheet(items: [s.url])
        }
        .toolAlert(m)
        .mirsaScreen()
    }

    private func load() async {
        guard let arr = await m.run("afc_ls", arg: path) as? [[String: Any]] else { return }
        entries = arr.compactMap { d in
            guard let n = d["name"] as? String, let p = d["path"] as? String else { return nil }
            return Entry(name: n, path: p, dir: (d["dir"] as? Bool) ?? false, size: Int64(num(d["size"]) ?? 0))
        }.sorted { ($0.dir ? 0 : 1, $0.name.lowercased()) < ($1.dir ? 0 : 1, $1.name.lowercased()) }
    }

    private func pull(_ e: Entry) async {
        let out = DeviceToolsModel.exportsDir.appendingPathComponent(e.name)
        try? FileManager.default.removeItem(at: out)
        if await m.run("afc_pull", arg: e.path, outPath: out.path) != nil { shareURL = out }
    }
}

private struct ShareItem: Identifiable { var id: URL { url }; let url: URL }

private struct MirsaShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
