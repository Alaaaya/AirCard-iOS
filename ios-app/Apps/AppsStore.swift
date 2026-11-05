import Foundation
import Security
import SwiftUI
import UIKit
import BackgroundTasks
import UserNotifications

/// Where an app lives.
enum AppLocation: String, Codable { case container, real }

/// One app managed by the Apps tab.
struct ManagedApp: Codable, Identifiable, Hashable {
    var id: String                 // original CFBundleIdentifier
    var name: String
    var version: String
    var sizeBytes: Int64
    var location: AppLocation
    var installedBundleID: String? // real apps: id with the team suffix
    var expires: Date?             // real apps: provisioning profile expiry
    var signedSerial: String?      // container apps: cert serial they were signed with
    var wantsNotifications: Bool
    var hasExtensions: Bool
    var addedAt: Date

    var daysLeft: Int? {
        guard let expires else { return nil }
        return max(0, Int(ceil(expires.timeIntervalSinceNow / 86_400)))
    }
}

/// An imported IPA waiting for the user to pick Container or Real App.
struct PendingImport: Identifiable {
    let id = UUID()
    let originalIPA: URL
    let extractedApp: URL
    let workDir: URL
    let bundleID: String
    let name: String
    let version: String
    let icon: UIImage?
    let wantsNotifications: Bool
    let hasExtensions: Bool
    let sizeBytes: Int64
}

struct AccountState: Equatable {
    var email: String = ""
    var teamName: String = ""
    var teamID: String = ""
    var certSerial: String = ""
    var certStatus: String = ""
    var certExpires: Date?
    var appIDsAvailable: Int?
    var appIDsMax: Int?
}

@MainActor
final class AppsStore: ObservableObject {
    static let shared = AppsStore()
    nonisolated static let bgTaskID = "com.alaa.mirsa.apps.refresh"

    @Published var apps: [ManagedApp] = []
    @Published var account: AccountState? = nil
    @Published var busy: String? = nil
    @Published var progress: Double = 0
    @Published var pending: PendingImport? = nil
    @Published var prompt: SideloadPrompt? = nil
    @Published var error: String? = nil
    @Published var toast: String? = nil
    /// Bundle id of the Mirsa that installSelf just installed (to open it).
    @Published var installedSelfBundleID: String? = nil
    /// This Mirsa was signed with an older certificate: offer a one-tap repair.
    @Published var needsRepair = false

    /// Built as "Mirsa Setup": a small installer that installs Mirsa with the
    /// user's Apple ID and hands over the login, signing key and pairing.
    nonisolated static var isSetupMode: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MirsaSetupMode") as? Bool ?? false
    }
    nonisolated static let handoffName = "MirsaHandoff.json"
    nonisolated static let handoffPairingName = "MirsaHandoff-pairing.plist"

    /// First launch of a Mirsa installed by Mirsa Setup: take over its
    /// Keychain items (same signing key = same certificate) and pairing file.
    nonisolated static func importHandoffIfNeeded() {
        guard !isSetupMode else { return }
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: "mirsa.handoff.done") else { return }
        let b = Bundle.main.bundleURL
        let fm = FileManager.default
        let j = b.appendingPathComponent(handoffName)
        if let d = try? Data(contentsOf: j),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
            Keychain.importAll(o)
        }
        let pf = b.appendingPathComponent(handoffPairingName)
        if fm.fileExists(atPath: pf.path) {
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dest = docs.appendingPathComponent("aircard_pairing.plist")
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: pf, to: dest) }
        }
        ud.set(true, forKey: "mirsa.handoff.done")
    }
    @Published var launchCandidate: ManagedApp? = nil

    @Published var realLimit: Int = {
        let v = UserDefaults.standard.integer(forKey: "apps.realLimit"); return v > 0 ? v : 3
    }() { didSet { UserDefaults.standard.set(realLimit, forKey: "apps.realLimit") } }
    @Published var autoRefresh: Bool = UserDefaults.standard.object(forKey: "apps.autoRefresh") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRefresh, forKey: "apps.autoRefresh") }
    }
    @Published var anisetteURL: String = UserDefaults.standard.string(forKey: "apps.anisetteURL") ?? "" {
        didSet { UserDefaults.standard.set(anisetteURL, forKey: "apps.anisetteURL") }
    }

    // MARK: Paths

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirCardApps", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var u = base
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
        return base
    }()
    static var originals: URL { dir("Originals") }
    static var containerApps: URL { dir("Container/Applications") }
    static var containerData: URL { dir("Container/Data") }
    static var icons: URL { dir("Icons") }
    private static func dir(_ p: String) -> URL {
        let u = root.appendingPathComponent(p, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private var dbURL: URL { Self.root.appendingPathComponent("apps.json") }

    /// iOS caches a file's code signature by inode, so a binary re-signed in
    /// place can keep failing with "code signature invalid". Copying the bundle
    /// gives every file a new inode.
    static func freshInodes(_ dir: URL) {
        let fm = FileManager.default
        let tmp = dir.deletingLastPathComponent().appendingPathComponent(".fresh-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.copyItem(at: dir, to: tmp)) != nil else { return }
        try? fm.removeItem(at: dir)
        if (try? fm.moveItem(at: tmp, to: dir)) == nil { try? fm.removeItem(at: tmp) }
    }

    /// Removes folders a failed launch nested inside a guest's data folder.
    static func cleanNestedLeftovers() {
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(at: containerData, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: d.appendingPathComponent("Library/Application Support/AirCardApps"))
        }
    }

    static func appDir(_ id: String) -> URL { containerApps.appendingPathComponent("\(id).app", isDirectory: true) }
    static func dataDir(_ id: String) -> URL { containerData.appendingPathComponent(id, isDirectory: true) }
    static func originalIPA(_ id: String) -> URL { originals.appendingPathComponent("\(id).ipa") }
    static func iconURL(_ id: String) -> URL { icons.appendingPathComponent("\(id).png") }

    // MARK: Lifecycle

    private init() {
        Self.cleanNestedLeftovers()
        SideloadService.configure()
        PromptBridge.shared.present = { [weak self] p in self?.prompt = p }
        load()
        // Signing scheme v2: guests are signed under Mirsa's own bundle id.
        if UserDefaults.standard.integer(forKey: "container.signRev") < 2 {
            for var a in apps where a.location == .container { a.signedSerial = nil; upsert(a) }
            UserDefaults.standard.set(2, forKey: "container.signRev")
        }
    }

    private func load() {
        let ud = UserDefaults.standard
        if let stage = ud.string(forKey: "mirsa.install.stage") {
            let last = ud.string(forKey: "mirsa.install.lastLog") ?? ""
            error = L.f("err.crashedAt", stage) + (last.isEmpty ? "" : "\n\n" + last)
            ud.removeObject(forKey: "mirsa.install.stage")
            ud.removeObject(forKey: "mirsa.install.lastLog")
        }
        guard let d = try? Data(contentsOf: dbURL),
              let a = try? JSONDecoder().decode([ManagedApp].self, from: d) else { return }
        apps = a
    }

    private func save() {
        if let d = try? JSONEncoder().encode(apps) { try? d.write(to: dbURL, options: .atomic) }
    }

    var containerApps: [ManagedApp] { apps.filter { $0.location == .container }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    var realApps: [ManagedApp] { apps.filter { $0.location == .real }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    /// Real-app slots used, counting AirCard itself.
    var slotsUsed: Int { 1 + realApps.count }
    var slotsLeft: Int { max(0, realLimit - slotsUsed) }

    var hasSavedLogin: Bool { Keychain.get("appleid.email") != nil && Keychain.get("appleid.password") != nil }

    // MARK: Network precondition (reuses the Pairing tab's VPN check)

    func networkReady(_ vm: AppViewModel?) -> Bool {
        let ip = vm?.deviceIP ?? "10.7.0.1"
        let s = NetworkStatus.summarize(deviceIP: ip)
        let hasPairing = FileManager.default.fileExists(atPath: PairingController.pairingFilePath())
        vm?.syncTargetHostsToRust()
        return s.vpn && s.wifi && hasPairing
    }

    // MARK: Account

    func signIn(email: String, password: String) async {
        busy = L.t("login.button")
        defer { busy = nil }
        do {
            _ = try await Task.detached { try SideloadService.login(email: email, password: password) }.value
            Keychain.set("appleid.email", email)
            Keychain.set("appleid.password", password)
            await refreshAccount()
            scheduleBackgroundRefresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Re-establish the session from Keychain without UI (launch / background).
    @discardableResult
    func ensureSession() async -> Bool {
        if SideloadService.isLoggedIn { return true }
        guard let e = Keychain.get("appleid.email"), let p = Keychain.get("appleid.password") else { return false }
        do {
            _ = try await Task.detached { try SideloadService.login(email: e, password: p) }.value
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func refreshAccount() async {
        guard await ensureSession() else { return }
        do {
            let o = try await Task.detached { try SideloadService.accountInfo() }.value
            var a = AccountState()
            a.email = o["email"] as? String ?? ""
            a.teamName = o["team_name"] as? String ?? ""
            a.teamID = o["team_id"] as? String ?? ""
            a.certSerial = o["cert_serial"] as? String ?? ""
            if let cs = o["cert_status"] as? [String: Any] {
                if let e = cs["error"] as? String { a.certStatus = "unknown (\(e))" }
                else {
                    let active = cs["active"] as? Bool ?? false
                    let list = (cs["on_account"] as? [String] ?? []).joined(separator: ", ")
                    a.certStatus = (active ? "ACTIVE" : "REVOKED / not on account") + " · on account: " + (list.isEmpty ? "none" : list)
                }
            }
            if let t = o["cert_expires"] as? Double { a.certExpires = Date(timeIntervalSince1970: t) }
            a.appIDsAvailable = o["app_ids_available"] as? Int
            a.appIDsMax = o["app_ids_max"] as? Int
            account = a
            needsRepair = !Self.isSetupMode && containerCertMismatch
            await resignContainerIfCertChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() {
        SideloadService.logout()
        Keychain.wipe()
        account = nil
    }

    /// Team ID of the certificate this copy of Mirsa is signed with (from its
    /// embedded provisioning profile). nil when there is no profile.
    lazy var ownTeamID: String? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"), let b = s.range(of: "</plist>") else { return nil }
        let xml = String(s[a.lowerBound..<b.upperBound])
        guard let d = xml.data(using: .isoLatin1),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return (p["TeamIdentifier"] as? [String])?.first
    }()

    /// Serial numbers (uppercase hex, no leading zeros) of the certificates the
    /// embedded provisioning profile allows.
    lazy var ownProfileCertSerials: [String] = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"), let b = s.range(of: "</plist>") else { return [] }
        let xml = String(s[a.lowerBound..<b.upperBound])
        guard let d = xml.data(using: .isoLatin1),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let certs = p["DeveloperCertificates"] as? [Data] else { return [] }
        return certs.compactMap { der in
            guard let c = SecCertificateCreateWithData(nil, der as CFData),
                  let sn = SecCertificateCopySerialNumberData(c, nil) as Data? else { return nil }
            let hex = sn.map { String(format: "%02X", $0) }.joined()
            let t = hex.drop(while: { $0 == "0" })
            return String(t)
        }
    }()

    /// Same team, but this Mirsa was signed with an older certificate than the
    /// one now used for Container apps (e.g. a new certificate was created after
    /// signing in on this copy). iOS then rejects the guest's signature.
    var containerCertMismatch: Bool {
        guard !containerTeamMismatch, let serial = account?.certSerial, !serial.isEmpty else { return false }
        let own = ownProfileCertSerials
        guard !own.isEmpty else { return false }
        let want = String(serial.uppercased().drop(while: { $0 == "0" }))
        return !own.contains(want)
    }

    /// Container apps can only load when this Mirsa is signed by the same team
    /// as the Apple ID that signs them (not an ESign/Feather certificate).
    var containerTeamMismatch: Bool {
        guard let own = ownTeamID, let acct = account?.teamID, !acct.isEmpty else { return false }
        return own != acct
    }

    /// Expiry of AirCard's own provisioning profile, when it has one.
    lazy var ownExpiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"), let b = s.range(of: "</plist>") else { return nil }
        let xml = String(s[a.lowerBound..<b.upperBound])
        guard let d = xml.data(using: .isoLatin1),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return p["ExpirationDate"] as? Date
    }()

    /// The date shown on the hero ring: soonest real-app expiry, else AirCard's own.
    var nextRenewal: Date? {
        let dates = realApps.compactMap(\.expires) + [ownExpiry].compactMap { $0 }
        return dates.min()
    }

    // MARK: Import

    func importIPA(from url: URL) async {
        busy = L.t("busy.importing")
        defer { busy = nil }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let ipa = work.appendingPathComponent("original.ipa")
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try fm.copyItem(at: url, to: ipa) } catch { self.error = error.localizedDescription; return }

        let extractDir = work.appendingPathComponent("x", isDirectory: true)
        let ok = await Task.detached { SideloadService.unzip(ipa.path, to: extractDir.path) }.value
        guard ok,
              let app = (try? fm.contentsOfDirectory(at: extractDir.appendingPathComponent("Payload"), includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any],
              let bid = info["CFBundleIdentifier"] as? String
        else { self.error = L.t("err.badIPA"); try? fm.removeItem(at: work); return }

        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bid
        let version = (info["CFBundleShortVersionString"] as? String) ?? "1.0"
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        let plugins = app.appendingPathComponent("PlugIns")
        let hasExt = ((try? fm.contentsOfDirectory(atPath: plugins.path)) ?? []).contains { $0.hasSuffix(".appex") }
        let size = (try? fm.attributesOfItem(atPath: ipa.path)[.size] as? Int64) ?? 0

        pending = PendingImport(originalIPA: ipa, extractedApp: app, workDir: work, bundleID: bid,
                                name: name, version: version, icon: Self.findIcon(in: app, info: info),
                                wantsNotifications: modes.contains("remote-notification"),
                                hasExtensions: hasExt, sizeBytes: size)
        if !url.standardizedFileURL.path.hasPrefix(DownloadsLibrary.root.standardizedFileURL.path) {
            DownloadsLibrary.shared.add(ipa: ipa, bundleID: bid, name: name, version: version, size: size, icon: pending?.icon)
        }
    }

    static func findIcon(in app: URL, info: [String: Any]) -> UIImage? {
        var names: [String] = []
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
            names += primary["CFBundleIconFiles"] as? [String] ?? []
            if let n = primary["CFBundleIconName"] as? String { names.append(n) }
        }
        names += info["CFBundleIconFiles"] as? [String] ?? []
        if let n = info["CFBundleIconFile"] as? String { names.append(n) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: app.path)) ?? []
        var best: (UIImage, CGFloat)?
        for base in names.reversed() + ["AppIcon"] {
            for f in files where f.hasPrefix(base) && f.hasSuffix(".png") {
                // iOS decodes Xcode's CgBI-optimised PNGs natively.
                if let img = UIImage(contentsOfFile: app.appendingPathComponent(f).path) {
                    let w = img.size.width * img.scale
                    if best == nil || w > best!.1 { best = (img, w) }
                }
            }
        }
        return best?.0
    }

    func cancelPending() {
        if let p = pending { try? FileManager.default.removeItem(at: p.workDir) }
        pending = nil
    }

    /// Finish the import into the chosen location.
    func commitPending(to location: AppLocation, vm: AppViewModel?) async {
        guard let p = pending else { return }
        pending = nil
        let fm = FileManager.default
        defer { try? fm.removeItem(at: p.workDir) }

        // Keep the original IPA: needed for refresh and for moving between locations.
        let orig = Self.originalIPA(p.bundleID)
        try? fm.removeItem(at: orig)
        do { try fm.moveItem(at: p.originalIPA, to: orig) } catch { self.error = error.localizedDescription; return }
        if let icon = p.icon, let png = icon.pngData() { try? png.write(to: Self.iconURL(p.bundleID)) }

        var app = apps.first(where: { $0.id == p.bundleID }) ?? ManagedApp(
            id: p.bundleID, name: p.name, version: p.version, sizeBytes: p.sizeBytes,
            location: location, installedBundleID: nil, expires: nil, signedSerial: nil,
            wantsNotifications: p.wantsNotifications, hasExtensions: p.hasExtensions, addedAt: Date())
        if location == .container, apps.contains(where: { $0.id == p.bundleID && $0.location == .container }) {
            await backupData(app, quiet: true)
        }
        app.name = p.name; app.version = p.version; app.sizeBytes = p.sizeBytes

        switch location {
        case .container:
            if await installToContainer(&app, extracted: p.extractedApp) { upsert(app) }
        case .real:
            if await installAsReal(&app, vm: vm) { upsert(app) }
        }
    }

    private func upsert(_ a: ManagedApp) {
        if let i = apps.firstIndex(where: { $0.id == a.id }) { apps[i] = a } else { apps.append(a) }
        save()
    }

    // MARK: Container

    private func installToContainer(_ app: inout ManagedApp, extracted: URL?) async -> Bool {
        guard await ensureSession() else { error = L.t("err.notSignedIn"); return false }
        busy = L.t("busy.signing")
        defer { busy = nil }
        let fm = FileManager.default
        let dest = Self.appDir(app.id)
        try? fm.removeItem(at: dest)
        do {
            if let extracted {
                try fm.moveItem(at: extracted, to: dest)
            } else {
                let tmp = fm.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: tmp) }
                let ipa = Self.originalIPA(app.id).path
                guard await Task.detached(operation: { SideloadService.unzip(ipa, to: tmp.path) }).value,
                      let a = (try? fm.contentsOfDirectory(at: tmp.appendingPathComponent("Payload"), includingPropertiesForKeys: nil))?
                        .first(where: { $0.pathExtension == "app" }) else { throw SideloadError.message(L.t("err.badIPA")) }
                try fm.moveItem(at: a, to: dest)
            }
            let path = dest.path
            let o = try await Task.detached { try SideloadService.containerSign(appDir: path) }.value
            Self.freshInodes(dest)
            app.signedSerial = o["cert_serial"] as? String
            app.location = .container
            app.installedBundleID = nil
            app.expires = nil
            try? fm.createDirectory(at: Self.dataDir(app.id), withIntermediateDirectories: true)
            toast = L.f("toast.installed", app.name)
            return true
        } catch {
            try? fm.removeItem(at: dest)
            self.error = error.localizedDescription
            return false
        }
    }

    /// After a failed load, sign every container app again on its next launch.
    func forceResignContainer() {
        for var a in containerApps { a.signedSerial = nil; upsert(a) }
    }

    /// Short report shown above a load error, to see which certificate is which.
    var signingDiagnostics: String {
        let n = { (s: String?) in String((s ?? "").uppercased().drop(while: { $0 == "0" })) }
        var lines = ["[Mirsa diag]"]
        lines.append("Mirsa team: \(ownTeamID ?? "none")  ·  Apple ID team: \(account?.teamID ?? "none")")
        lines.append("Mirsa profile certs: \(ownProfileCertSerials.isEmpty ? "none" : ownProfileCertSerials.joined(separator: ", "))")
        lines.append("Signing cert: \(n(account?.certSerial).isEmpty ? "none" : n(account?.certSerial))")
        lines.append("Signing cert on Apple: \(account?.certStatus.isEmpty == false ? account!.certStatus : "not checked")")
        for a in containerApps { lines.append("\(a.name) signed with: \(n(a.signedSerial).isEmpty ? "re-sign pending" : n(a.signedSerial))") }
        lines.append("Setup mode: \(Self.isSetupMode ? "yes" : "no")  ·  bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        return lines.joined(separator: "\n")
    }

    /// Self-test for the container signer, shown with a load error:
    /// A = Mirsa's own (installd-accepted) executable copied into the data
    /// container; B = the same copy re-signed by the container signer.
    /// If A passes and B fails, the signer output is at fault; if both fail,
    /// iOS refuses developer-signed code loaded from the data container.
    func signerSelfTest() async -> String {
        let probe = Bundle.main.bundleURL.appendingPathComponent("Frameworks/MirsaProbe.dylib")
        let fm = FileManager.default
        guard fm.fileExists(atPath: probe.path) else { return "[self-test] probe library missing" }
        let dir = Self.appDir("selftest")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a-\(UUID().uuidString).dylib")
        let b = dir.appendingPathComponent("b-\(UUID().uuidString).dylib")
        var out = ["[self-test]"]
        // Remove the certificate export left by an earlier test build.
        try? fm.removeItem(at: fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Mirsa-Certificate.p12"))
        if let f = MirsaProcessFlags() { out.append("process: " + String(cString: f)); free(f) }
        out.append("iOS \(UIDevice.current.systemVersion)")
        out.append("0 (in Mirsa bundle): " + Self.kernelCheck(probe.path))
        // Probe inside a fake .app that carries Mirsa's provisioning profile.
        let fakeApp = Self.appDir("selftest-app").appendingPathComponent("Probe.app")
        try? fm.removeItem(at: fakeApp.deletingLastPathComponent())
        try? fm.createDirectory(at: fakeApp, withIntermediateDirectories: true)
        let prof = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        try? fm.copyItem(at: prof, to: fakeApp.appendingPathComponent("embedded.mobileprovision"))
        try? fm.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Info.plist"), to: fakeApp.appendingPathComponent("Info.plist"))
        let inApp = fakeApp.appendingPathComponent("MirsaProbe.dylib")
        if (try? fm.copyItem(at: probe, to: inApp)) != nil {
            out.append("A-app (with profile): " + Self.kernelCheck(inApp.path))
        }
        try? fm.removeItem(at: fakeApp.deletingLastPathComponent())
        for (label, base) in [("Documents", fm.urls(for: .documentDirectory, in: .userDomainMask)[0]),
                              ("tmp", fm.temporaryDirectory)] {
            let t = base.appendingPathComponent("probe-\(UUID().uuidString).dylib")
            if (try? fm.copyItem(at: probe, to: t)) != nil {
                out.append("A-\(label): " + Self.kernelCheck(t.path))
                try? fm.removeItem(at: t)
            }
        }
        do {
            try fm.copyItem(at: probe, to: a)
            out.append("A (copied as-is): " + Self.kernelCheck(a.path))
            try fm.copyItem(at: probe, to: b)
            let bp = b.path, ident = Bundle.main.bundleIdentifier ?? ""
            if await ensureSession() {
                try await Task.detached { try SideloadService.containerSignFile(path: bp, ident: ident) }.value
                let fresh = dir.appendingPathComponent("c-\(UUID().uuidString).dylib")
                try fm.copyItem(at: b, to: fresh)
                out.append("B (re-signed by Mirsa): " + Self.kernelCheck(fresh.path))
            } else {
                out.append("B: not signed in")
            }
        } catch { out.append("error: \(error.localizedDescription)") }
        try? fm.removeItem(at: dir)
        return out.joined(separator: "\n")
    }

    static func kernelCheck(_ path: String) -> String {
        guard let p = MirsaKernelCheck(path) else { return "?" }
        defer { free(p) }
        return String(cString: p)
    }

    /// After the development certificate changes, re-sign every container app.
    func resignContainerIfCertChanged() async {
        guard let serial = account?.certSerial, !serial.isEmpty else { return }
        for var a in containerApps where a.signedSerial != serial {
            let path = Self.appDir(a.id).path
            if let o = try? await Task.detached(operation: { try SideloadService.containerSign(appDir: path) }).value {
                Self.freshInodes(Self.appDir(a.id))
                a.signedSerial = o["cert_serial"] as? String
                upsert(a)
            }
        }
    }

    func resign(_ app: ManagedApp) async {
        guard await ensureSession() else { error = L.t("err.notSignedIn"); return }
        busy = L.t("busy.signing"); defer { busy = nil }
        var a = app
        let path = Self.appDir(a.id).path
        do {
            let o = try await Task.detached { try SideloadService.containerSign(appDir: path) }.value
            a.signedSerial = o["cert_serial"] as? String
            upsert(a)
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Real apps

    private func installAsReal(_ app: inout ManagedApp, vm: AppViewModel?) async -> Bool {
        let alreadyReal = app.location == .real && apps.contains(where: { $0.id == app.id && $0.location == .real })
        if !alreadyReal && slotsLeft <= 0 { error = L.t("choice.full"); return false }
        guard networkReady(vm) else { error = L.t("err.vpn"); return false }
        guard await ensureSession() else { error = L.t("err.notSignedIn"); return false }
        busy = L.t("busy.installing"); progress = 0
        defer { busy = nil }
        let ipa = Self.originalIPA(app.id).path
        do {
            let o = try await Task.detached {
                try SideloadService.install(appPath: ipa) { f, _ in
                    Task { @MainActor in AppsStore.shared.progress = f }
                }
            }.value
            app.location = .real
            app.installedBundleID = o["bundle_id"] as? String
            if let t = o["expires"] as? Double { app.expires = Date(timeIntervalSince1970: t) }
            else { app.expires = Date().addingTimeInterval(7 * 86_400) }
            toast = L.f("toast.installed", app.name)
            await refreshAccount()
            return true
        } catch {
            self.error = Self.friendly(error)
            return false
        }
    }

    func refresh(_ app: ManagedApp, vm: AppViewModel?) async {
        var a = app
        if await installAsReal(&a, vm: vm) { upsert(a) }
    }

    /// Re-install every real app (new 7-day profile). Used by the button,
    /// the App Intent and the background task.
    @discardableResult
    /// `withinDays`: only renew apps that expire within that many days (nil = all).
    /// When Mirsa itself is due too, it renews itself last (which relaunches it).
    func refreshAll(vm: AppViewModel?, withinDays: Int? = nil) async -> Int {
        var n = 0
        let due = { (exp: Date?) -> Bool in
            guard let w = withinDays, let exp else { return true }
            return exp.timeIntervalSinceNow <= Double(w) * 86_400
        }
        for app in realApps where due(app.expires) {
            var a = app
            if await installAsReal(&a, vm: vm) { upsert(a); n += 1 }
        }
        await resignContainerIfCertChanged()
        if n > 0 { toast = L.f("toast.refreshed", n) }
        if withinDays != nil, let own = ownExpiry, due(own) {
            scheduleExpiryReminders()
            await installSelf(vm: vm)
        }
        return n
    }

    // MARK: Move / delete

    func move(_ app: ManagedApp, to location: AppLocation, vm: AppViewModel?) async {
        var a = app
        switch location {
        case .real:
            guard slotsLeft > 0 else { error = L.t("choice.full"); return }
            if await installAsReal(&a, vm: vm) {
                try? FileManager.default.removeItem(at: Self.appDir(app.id))
                upsert(a)
            }
        case .container:
            if await installToContainer(&a, extracted: nil) {
                if let bid = app.installedBundleID, networkReady(vm) {
                    _ = try? await Task.detached { try SideloadService.uninstall(bundleID: bid) }.value
                }
                upsert(a)
            }
        }
    }

    func delete(_ app: ManagedApp, vm: AppViewModel?) async {
        let fm = FileManager.default
        if app.location == .container { await backupData(app, quiet: true) }
        if app.location == .real, let bid = app.installedBundleID, networkReady(vm) {
            _ = try? await Task.detached { try SideloadService.uninstall(bundleID: bid) }.value
        }
        try? fm.removeItem(at: Self.appDir(app.id))
        try? fm.removeItem(at: Self.dataDir(app.id))
        try? fm.removeItem(at: Self.originalIPA(app.id))
        try? fm.removeItem(at: Self.iconURL(app.id))
        apps.removeAll { $0.id == app.id }
        save()
    }

    // MARK: Self-install (AirCard signed by the user's Apple ID)

    /// Container apps must be signed by the same team as the AirCard that loads
    /// them. This installs a copy of AirCard signed with the user's Apple ID.
    func installSelf(vm: AppViewModel?, from source: URL? = nil) async {
        guard networkReady(vm) else { error = L.t("err.vpn"); return }
        guard await ensureSession() else { error = L.t("err.notSignedIn"); return }
        busy = L.t("busy.installing"); progress = 0
        defer { busy = nil }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("self-\(UUID().uuidString)", isDirectory: true)
        let copy = tmp.appendingPathComponent("AirCard.app", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            try fm.copyItem(at: source ?? Bundle.main.bundleURL, to: copy)
            // Normalise the bundle id so isideload appends the team id once.
            let plistURL = copy.appendingPathComponent("Info.plist")
            if let info = NSMutableDictionary(contentsOf: plistURL) {
                info["CFBundleIdentifier"] = "com.alaa.mirsa"
                info["CFBundleDisplayName"] = "Mirsa"
                info["CFBundleName"] = "Mirsa"
                info.removeObject(forKey: "MirsaSetupMode")
                if source != nil, let bg = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") {
                    info["BGTaskSchedulerPermittedIdentifiers"] = bg
                }
                _ = info.write(to: plistURL, atomically: true)
            }
            // Never carry an old handoff along; Setup writes a fresh one.
            try? fm.removeItem(at: copy.appendingPathComponent(Self.handoffName))
            try? fm.removeItem(at: copy.appendingPathComponent(Self.handoffPairingName))
            if Self.isSetupMode {
                let kc = Keychain.exportAll()
                if let d = try? JSONSerialization.data(withJSONObject: kc) {
                    try d.write(to: copy.appendingPathComponent(Self.handoffName))
                }
                let pf = PairingController.pairingFilePath()
                if fm.fileExists(atPath: pf) {
                    try? fm.copyItem(at: URL(fileURLWithPath: pf), to: copy.appendingPathComponent(Self.handoffPairingName))
                }
            }
            let path = copy.path
            let o = try await Task.detached {
                try SideloadService.install(appPath: path) { f, _ in Task { @MainActor in AppsStore.shared.progress = f } }
            }.value
            installedSelfBundleID = o["bundle_id"] as? String
            needsRepair = false
            toast = L.f("toast.installed", "Mirsa")
        } catch { self.error = Self.friendly(error) }
    }

    /// Turn the raw connection error into something readable, keeping the detail.
    static func friendly(_ error: Error) -> String {
        let raw = error.localizedDescription
        if raw.contains("Device connection failed") || raw.contains("RemoteXPC") || raw.contains("timed out") {
            return L.t("err.device") + "\n\n" + raw
        }
        return raw
    }

    // MARK: Launch

    /// Container: hand the app to the loader and relaunch AirCard into it.
    func launch(_ app: ManagedApp) {
        switch app.location {
        case .real:
            guard let bid = app.installedBundleID else { return }
            _ = AppsStore.openInstalledApp(bundleID: bid)
        case .container:
            if containerTeamMismatch { error = L.t("err.teamMismatch"); return }
            if containerCertMismatch { error = L.t("err.certMismatch"); return }
            // Signed with an older certificate (or never re-signed since Mirsa
            // changed): sign again with the current one before loading it.
            let norm = { (s: String?) in String((s ?? "").uppercased().drop(while: { $0 == "0" })) }
            if let cur = account?.certSerial, !cur.isEmpty, norm(app.signedSerial) != norm(cur) {
                Task {
                    var a = app
                    busy = L.t("busy.signing")
                    let path = Self.appDir(a.id).path
                    do {
                        let o = try await Task.detached { try SideloadService.containerSign(appDir: path) }.value
                        Self.freshInodes(Self.appDir(a.id))
                        a.signedSerial = o["cert_serial"] as? String
                        upsert(a)
                        busy = nil
                        confirmLaunch(a)
                    } catch {
                        busy = nil
                        self.error = error.localizedDescription
                    }
                }
                return
            }
            confirmLaunch(app)
        }
    }

    func confirmLaunch(_ app: ManagedApp) {
        launchCandidate = nil
        let d = UserDefaults.standard
        d.set(Self.appDir(app.id).path, forKey: "aircard.guest.bundlePath")
        d.set(Self.dataDir(app.id).path, forKey: "aircard.guest.dataPath")
        d.removeObject(forKey: "aircard.guest.lastError")
        d.synchronize()

        // Like LiveContainer: ask iOS to open Mirsa again and end this
        // process; it comes straight back with the guest app.
        // If we are still alive after a moment, fall back to the notification.
        if MirsaRelaunchSelf() != 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.relaunchViaNotification(app)
            }
            return
        }
        relaunchViaNotification(app)
    }

    private func relaunchViaNotification(_ app: ManagedApp) {
        // Fallback: a notification the user taps to come back.
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                let c = UNMutableNotificationContent()
                c.title = "Mirsa"
                c.body = L.f("notif.tap", app.name)
                let req = UNNotificationRequest(identifier: "aircard.guest.relaunch", content: c,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
                center.add(req)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                UIControl().sendAction(NSSelectorFromString("suspend"), to: UIApplication.shared, for: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(0) }
            }
        }
    }

    /// Last loader error (set by GuestLoader.m when dlopen fails).
    var lastLaunchError: String? { UserDefaults.standard.string(forKey: "aircard.guest.lastError") }

    static func openInstalledApp(bundleID: String) -> Bool {
        guard let cls: AnyObject = NSClassFromString("LSApplicationWorkspace"),
              let ws = cls.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
        else { return false }
        let sel = NSSelectorFromString("openApplicationWithBundleID:")
        guard ws.responds(to: sel) else { return false }
        return ws.perform(sel, with: bundleID) != nil
    }

    // MARK: Background refresh

    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskID, using: nil) { task in
            let work = Task { @MainActor in
                if GitHubWatcher.shared.autoInstall { await GitHubWatcher.shared.checkAll(install: true) }
                let n = await AppsStore.shared.refreshAll(vm: AppViewModel.shared, withinDays: 2)
                AppsStore.shared.scheduleBackgroundRefresh()
                task.setTaskCompleted(success: n >= 0)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    func scheduleBackgroundRefresh() {
        scheduleExpiryReminders()
        guard autoRefresh, !realApps.isEmpty || !GitHubWatcher.shared.sources.isEmpty else { return }
        let req = BGProcessingTaskRequest(identifier: Self.bgTaskID)
        req.requiresNetworkConnectivity = true
        // Aim for ~2 days before the soonest expiry; iOS decides the exact time.
        let soon = nextRenewal?.addingTimeInterval(-2 * 86_400) ?? Date().addingTimeInterval(86_400)
        req.earliestBeginDate = max(Date().addingTimeInterval(3_600), soon)
        try? BGTaskScheduler.shared.submit(req)
    }
}

@_silgen_name("MirsaKernelCheck")
func MirsaKernelCheck(_ path: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("MirsaRelaunchSelf")
func MirsaRelaunchSelf() -> Int32

@_silgen_name("MirsaProcessFlags")
func MirsaProcessFlags() -> UnsafeMutablePointer<CChar>?
