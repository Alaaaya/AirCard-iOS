import Foundation
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

    static func appDir(_ id: String) -> URL { containerApps.appendingPathComponent("\(id).app", isDirectory: true) }
    static func dataDir(_ id: String) -> URL { containerData.appendingPathComponent(id, isDirectory: true) }
    static func originalIPA(_ id: String) -> URL { originals.appendingPathComponent("\(id).ipa") }
    static func iconURL(_ id: String) -> URL { icons.appendingPathComponent("\(id).png") }

    // MARK: Lifecycle

    private init() {
        SideloadService.configure()
        PromptBridge.shared.present = { [weak self] p in self?.prompt = p }
        load()
    }

    private func load() {
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
            if let t = o["cert_expires"] as? Double { a.certExpires = Date(timeIntervalSince1970: t) }
            a.appIDsAvailable = o["app_ids_available"] as? Int
            a.appIDsMax = o["app_ids_max"] as? Int
            account = a
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

    /// After the development certificate changes, re-sign every container app.
    func resignContainerIfCertChanged() async {
        guard let serial = account?.certSerial, !serial.isEmpty else { return }
        for var a in containerApps where a.signedSerial != serial {
            let path = Self.appDir(a.id).path
            if let o = try? await Task.detached(operation: { try SideloadService.containerSign(appDir: path) }).value {
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
            self.error = error.localizedDescription
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
    func refreshAll(vm: AppViewModel?) async -> Int {
        var n = 0
        for app in realApps {
            var a = app
            if await installAsReal(&a, vm: vm) { upsert(a); n += 1 }
        }
        await resignContainerIfCertChanged()
        if n > 0 { toast = L.f("toast.refreshed", n) }
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
    func installSelf(vm: AppViewModel?) async {
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
            try fm.copyItem(at: Bundle.main.bundleURL, to: copy)
            // Normalise the bundle id so isideload appends the team id once.
            let plistURL = copy.appendingPathComponent("Info.plist")
            if let info = NSMutableDictionary(contentsOf: plistURL) {
                info["CFBundleIdentifier"] = "com.alaa.mirsa"
                _ = info.write(to: plistURL, atomically: true)
            }
            let path = copy.path
            _ = try await Task.detached {
                try SideloadService.install(appPath: path) { f, _ in Task { @MainActor in AppsStore.shared.progress = f } }
            }.value
            toast = L.f("toast.installed", "Mirsa")
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Launch

    /// Container: hand the app to the loader and relaunch AirCard into it.
    func launch(_ app: ManagedApp) {
        switch app.location {
        case .real:
            guard let bid = app.installedBundleID else { return }
            _ = AppsStore.openInstalledApp(bundleID: bid)
        case .container:
            launchCandidate = app
        }
    }

    func confirmLaunch(_ app: ManagedApp) {
        launchCandidate = nil
        let d = UserDefaults.standard
        d.set(Self.appDir(app.id).path, forKey: "aircard.guest.bundlePath")
        d.set(Self.dataDir(app.id).path, forKey: "aircard.guest.dataPath")
        d.removeObject(forKey: "aircard.guest.lastError")
        d.synchronize()

        // Ask iOS to bring us back: a local notification the user can tap if
        // the system does not relaunch AirCard by itself.
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
                let n = await AppsStore.shared.refreshAll(vm: AppViewModel.shared)
                AppsStore.shared.scheduleBackgroundRefresh()
                task.setTaskCompleted(success: n >= 0)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    func scheduleBackgroundRefresh() {
        guard autoRefresh, !realApps.isEmpty else { return }
        let req = BGProcessingTaskRequest(identifier: Self.bgTaskID)
        req.requiresNetworkConnectivity = true
        // Aim for ~2 days before the soonest expiry; iOS decides the exact time.
        let soon = nextRenewal?.addingTimeInterval(-2 * 86_400) ?? Date().addingTimeInterval(86_400)
        req.earliestBeginDate = max(Date().addingTimeInterval(3_600), soon)
        try? BGTaskScheduler.shared.submit(req)
    }
}
