import SwiftUI
import CryptoKit
import UIKit

// MARK: - Provenance sidecar

struct DiscoveryProvenance: Codable, Equatable {
    var bundleID: String
    var version: String
    var sourceName: String
    var sourceURL: String
    /// Host + path only. Signed query strings expire and are never stored.
    var downloadLocation: String
    var origin: String
    var identity: String
    var sourceAuthorizedByOwner: Bool
    var sha256: String
    var addedAt: Date

    static func strip(_ u: URL) -> String { (u.host ?? "") + u.path }
    static let fileName = "provenance.json"
}

// MARK: - Store

@MainActor
final class DiscoveryStore: ObservableObject {
    enum CardState: Equatable {
        case idle, downloading(Double), validating, added(String), failed(String), dismissed
    }

    @Published var input = ""
    @Published var searching = false
    @Published var outcome: DiscoveryOutcome?
    @Published var states: [String: CardState] = [:]
    @Published var authorization: DiscoveryAuthorization

    private static let authKey = "mirsa.discovery.authorized.v1"
    private var downloaders: [String: DiscoveryDownloader] = [:]
    private let http = SafeMetadataHTTP()

    init() {
        let list = UserDefaults.standard.stringArray(forKey: Self.authKey) ?? []
        authorization = DiscoveryAuthorization(authorizedSources: Set(list))
    }

    private func saveAuth() { UserDefaults.standard.set(Array(authorization.authorizedSources), forKey: Self.authKey) }

    func trust(_ c: DiscoveryCandidate) { authorization.authorize(c.sourceURL); saveAuth() }
    func untrust(_ c: DiscoveryCandidate) { authorization.revoke(c.sourceURL); saveAuth() }
    func isAuthorized(_ c: DiscoveryCandidate) -> Bool { authorization.isAuthorized(sourceURL: c.sourceURL) }

    private func snapshots() -> [DiscoverySourceSnapshot] {
        let store = SourcesStore.shared
        let builtIn = Set(SourcesStore.builtIn.map { DiscoveryAuthorization.normalize($0.url) })
        return store.visibleSources.map { s in
            DiscoverySourceSnapshot(name: s.name, url: s.url, isBuiltIn: builtIn.contains(DiscoveryAuthorization.normalize(s.url)),
                apps: (store.apps[s.url] ?? []).map {
                    .init(name: $0.name, bundleID: $0.bundleID, developer: $0.developer, version: $0.version,
                          iconURL: $0.iconURL, downloadURL: $0.downloadURL)
                })
        }
    }

    func search() async {
        let text = input
        guard !searching else { return }
        searching = true; outcome = nil; states = [:]
        defer { searching = false }
        if SourcesStore.shared.apps.isEmpty { await SourcesStore.shared.refreshAll() }
        let web = WebBackendConfig.load(token: DiscoveryKeychain.token())
        let result = await DiscoveryEngine.run(input: text, sources: snapshots(), web: web, http: http)
        outcome = result
    }

    func dismiss(_ c: DiscoveryCandidate) { states[c.id] = .dismissed }

    func cancel(_ c: DiscoveryCandidate) { downloaders[c.id]?.cancel() }

    /// "Yes": download, validate, add to Downloads. Installation stays a separate step.
    func accept(_ c: DiscoveryCandidate) async {
        guard c.isDownloadable, let url = c.downloadURL else { return }
        if case .downloading = states[c.id] ?? .idle { return }
        let d = DiscoveryDownloader()
        downloaders[c.id] = d
        states[c.id] = .downloading(0)
        var temp: URL?
        defer { if let t = temp { try? FileManager.default.removeItem(at: t) }; downloaders[c.id] = nil }
        do {
            let file = try await d.download(url) { [weak self] p in Task { @MainActor in
                if case .downloading = self?.states[c.id] ?? .idle { self?.states[c.id] = .downloading(p) } } }
            temp = file
            states[c.id] = .validating
            let expectedBundle: String? = c.bundleID.range(of: IPAValidator.bundleIDPattern, options: .regularExpression) != nil ? c.bundleID : nil
            let expectedVersion = c.version
            let os = UIDevice.current.systemVersion
            let facts = try await Task.detached(priority: .userInitiated) {
                try IPAValidator.validate(file: file, expectedBundleID: expectedBundle, expectedVersion: expectedVersion, deviceOS: os)
            }.value
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            let hash = try await Task.detached { try Self.sha256(file) }.value
            DownloadsLibrary.shared.add(ipa: file, bundleID: facts.bundleID, name: facts.displayName,
                                        version: facts.version, size: size, icon: nil)
            let item = DownloadItem(bundleID: facts.bundleID, name: facts.displayName, version: facts.version, size: size, date: Date())
            guard FileManager.default.fileExists(atPath: DownloadsLibrary.ipaURL(item).path) else {
                states[c.id] = .failed(tr("Couldn't save it to Downloads.", "ما قدرت احفظه بالتنزيلات.")); return
            }
            let prov = DiscoveryProvenance(bundleID: facts.bundleID, version: facts.version, sourceName: c.sourceName, sourceURL: c.sourceURL,
                downloadLocation: DiscoveryProvenance.strip(url), origin: c.origin.rawValue, identity: c.identity.rawValue,
                sourceAuthorizedByOwner: isAuthorized(c), sha256: hash, addedAt: Date())
            let dir = DownloadsLibrary.folder(facts.bundleID, facts.version)
            try JSONEncoder().encode(prov).write(to: dir.appendingPathComponent(DiscoveryProvenance.fileName))
            states[c.id] = .added(facts.displayName + " " + facts.version)
        } catch {
            states[c.id] = .failed(error.localizedDescription)
        }
    }

    nonisolated static func sha256(_ file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Keychain for the optional web backend token (nothing compiled in)

enum DiscoveryKeychain {
    private static let service = "com.alaa.mirsa.discovery"
    static func token() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func setToken(_ t: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let t, !t.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(t.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - View

struct DiscoveryView: View {
    @StateObject private var store = DiscoveryStore()
    @Environment(\.dismiss) private var dismissSheet
    @State private var pendingTrust: DiscoveryCandidate?
    @State private var showWeb = false
    @State private var endpoint = UserDefaults.standard.string(forKey: WebBackendConfig.endpointKey) ?? ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    searchField
                    Text(tr("Type an app name or paste an App Store link. Mirsa looks through your sources and shows what it found. Nothing downloads until you say yes.",
                            "اكتب اسم تطبيق أو الصق رابط App Store. Mirsa بيدور بالسورسات تبعك وبيعرضلك اللي لقاه. ما بينزل شي إلا لما توافق."))
                        .font(.footnote).foregroundStyle(.white.opacity(0.65))
                    if store.searching { ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 20) }
                    if let o = store.outcome {
                        if let n = o.note {
                            Text(n).font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        }
                        ForEach(o.candidates.filter { store.states[$0.id] != .dismissed }) { c in card(c) }
                        providerRows(o.reports)
                    }
                }
                .padding(16)
            }
            .environment(\.layoutDirection, .leftToRight)
            .navigationTitle(tr("Find an app", "دوّر على تطبيق"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(tr("Close", "إغلاق")) { dismissSheet() } }
                ToolbarItem(placement: .topBarTrailing) { Button { showWeb = true } label: { Image(systemName: "network") } }
            }
            .sheet(isPresented: $showWeb) { webSettings }
            .confirmationDialog(tr("This source isn't marked as authorized", "هالسورس مو معلّم كمصرّح"), isPresented: Binding(get: { pendingTrust != nil }, set: { if !$0 { pendingTrust = nil } }), titleVisibility: .visible) {
                if let c = pendingTrust {
                    Button(tr("Download once", "نزّل مرة وحدة")) { Task { await store.accept(c) } }
                    Button(tr("I confirm this source may distribute it, remember", "أؤكد إنو السورس مصرّح، تذكّر")) { store.trust(c); Task { await store.accept(c) } }
                    Button(tr("Cancel", "إلغاء"), role: .cancel) {}
                }
            } message: {
                Text(tr("Provenance is unknown. Only continue if the app's author allows this distribution.",
                        "المصدر مجهول. كمّل بس إذا صاحب التطبيق مسموح بهالتوزيع."))
            }
            .mirsaScreen()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
            TextField(tr("Name or App Store link", "اسم أو رابط App Store"), text: $store.input)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await store.search() } }
            if !store.input.isEmpty {
                Button { store.input = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }
            }
            Button { Task { await store.search() } } label: {
                Text(tr("Search", "بحث")).font(.subheadline.weight(.bold)).padding(.horizontal, 12).padding(.vertical, 6)
            }
            .appsGlassCapsule(tint: Color(red: 0.45, green: 0.4, blue: 1))
            .disabled(store.searching || store.input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .appsGlass(cornerRadius: 20)
    }

    private func badge(_ text: String, _ color: Color, _ icon: String) -> some View {
        Label(text, systemImage: icon).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3).background(color.opacity(0.15), in: Capsule())
    }

    private func card(_ c: DiscoveryCandidate) -> some View {
        let state = store.states[c.id] ?? .idle
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RemoteIcon(url: c.iconURL, size: 56, corner: 13)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name).font(.headline).foregroundStyle(.white).lineLimit(2)
                    Text([c.developer, c.version.isEmpty ? nil : "v" + c.version].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    Text(c.bundleID).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(tr("Source: ", "المصدر: ") + c.sourceName).font(.caption).foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 6) {
                switch c.identity {
                case .bundleVerified: badge(tr("Bundle ID matches", "المعرّف مطابق"), .green, "checkmark.seal")
                case .nameOnly: badge(tr("Identity unverified, name only", "الهوية غير مؤكدة، الاسم فقط"), .orange, "questionmark.circle")
                case .reference: badge(tr("Reference only, no download", "مرجع فقط، بدون تنزيل"), .gray, "info.circle")
                }
                if c.isDownloadable {
                    if store.isAuthorized(c) { badge(tr("You authorized this source", "إنت صرّحت هالسورس"), .green, "person.badge.shield.checkmark") }
                    else { badge(tr("Provenance unknown", "المصدر مجهول"), .orange, "exclamationmark.triangle") }
                }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            actions(c, state)
        }
        .padding(14)
        .appsGlass(cornerRadius: 22)
    }

    @ViewBuilder private func actions(_ c: DiscoveryCandidate, _ state: DiscoveryStore.CardState) -> some View {
        switch state {
        case .downloading(let p):
            HStack {
                ProgressView(value: p).tint(.white)
                Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                Button(tr("Cancel", "إلغاء")) { store.cancel(c) }.font(.caption.weight(.bold))
            }
        case .validating:
            HStack { ProgressView().tint(.white); Text(tr("Checking the file…", "عم أفحص الملف…")).font(.caption).foregroundStyle(.white.opacity(0.8)) }
        case .added(let t):
            Label(tr("Added to Downloads: ", "انضاف للتنزيلات: ") + t + tr(". Install it from Downloads.", ". نصّبه من التنزيلات."), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let m):
            VStack(alignment: .leading, spacing: 6) {
                Label(m, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                Button(tr("Try again", "جرّب مرة ثانية")) { store.states[c.id] = .idle }.font(.caption.weight(.bold))
            }
        case .idle, .dismissed:
            if c.isDownloadable {
                HStack(spacing: 10) {
                    Button { if store.isAuthorized(c) { Task { await store.accept(c) } } else { pendingTrust = c } } label: {
                        Text(tr("Yes, download", "إي، نزّل")).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                    }
                    .appsGlassCapsule(tint: .green)
                    Button { store.dismiss(c) } label: {
                        Text(tr("No", "لا")).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                    }
                    .appsGlassCapsule(tint: .red)
                }
            } else {
                Button { store.dismiss(c) } label: { Text(tr("Dismiss", "إخفاء")).font(.caption.weight(.bold)) }
            }
        }
    }

    private func providerRows(_ reports: [ProviderReport]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(reports, id: \.provider) { r in
                HStack(alignment: .top, spacing: 8) {
                    switch r.status {
                    case .ok(let n): Image(systemName: "checkmark.circle").foregroundStyle(.green); Text("\(r.provider): \(n)")
                    case .unavailable(let s): Image(systemName: "exclamationmark.circle").foregroundStyle(.orange); Text("\(r.provider): \(s)")
                    case .blocked(let s): Image(systemName: "lock.circle").foregroundStyle(.gray); Text("\(r.provider): \(s)")
                    }
                }
                .font(.caption).foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.top, 6)
    }

    private var webSettings: some View {
        NavigationStack {
            Form {
                Section(tr("Search backend (optional)", "باك إند البحث (اختياري)")) {
                    TextField("https://…", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField(tr("Token (optional)", "التوكن (اختياري)"), text: $token)
                }
                Section {
                    Text(tr("Without a backend, discovery only searches your sources and Apple's public metadata. Telegram search is not available.",
                            "بدون باك إند البحث بيكون بالسورسات وبيانات Apple العامة فقط. بحث تيليجرام مو متاح."))
                        .font(.footnote)
                }
            }
            .navigationTitle(tr("Web search", "بحث الويب"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Save", "حفظ")) {
                        UserDefaults.standard.set(endpoint.trimmingCharacters(in: .whitespaces), forKey: WebBackendConfig.endpointKey)
                        if !token.isEmpty { DiscoveryKeychain.setToken(token) }
                        showWeb = false
                    }
                }
            }
            .mirsaScreen()
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}
