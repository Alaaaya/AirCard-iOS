import SwiftUI

/// Install through a saved personal certificate (P12 + profile): sign locally,
/// then push the signed app with installation_proxy. No Apple ID, no free-slot
/// use. The profile inside the app still limits devices, bundle ID and expiry,
/// and iOS may refuse an expired, revoked or untrusted certificate. Nothing is
/// bypassed and no "unlimited" claim is made.
enum CertificateInstall {
    enum Failure: LocalizedError {
        case busy, missingIPA, noApp(String)
        /// Install failed after signing; the signed IPA lives at `signedURL`.
        case retained(String, signedURL: URL)
        var errorDescription: String? {
            switch self {
            case .busy: return personalText("Another install is running.", "في عملية ثانية شغّالة هلأ.")
            case .missingIPA: return personalText("The IPA file is missing.", "ملف الـIPA مو موجود.")
            case .noApp(let m): return m
            case .retained(let m, _): return m
            }
        }
    }

    /// Returns a .app folder inside a staging folder this call created.
    /// `stage` is the only thing the caller may delete afterwards.
    static func stageSignedApp(ipa: URL, in parent: URL) throws -> (stage: URL, app: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard ipa.isFileURL, ipa.path.hasPrefix("/"), fm.fileExists(atPath: ipa.path, isDirectory: &isDir),
              !isDir.boolValue, ipa.pathExtension.lowercased() == "ipa" else { throw Failure.noApp("Signed IPA path is not valid.") }
        let stage = parent.appendingPathComponent("cert-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.complete])
        do {
            try IPAEditorService.run("extract", input: ipa, output: stage)
            return (stage, try IPAEditorService.app(in: stage))
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
    }

    @MainActor private static var running = false

    /// Signs `input` with `identity`, installs it, and reports one operation.
    /// On install failure the signed IPA is kept and its URL is in the error text.
    @MainActor
    static func run(input: URL, appID: String?, identity: PersonalIdentityVault.SavedIdentity,
                    store: AppsStore? = nil) async throws -> [String: Any] {
        guard !running, store?.busy == nil else { throw Failure.busy }
        guard FileManager.default.fileExists(atPath: input.path) else { throw Failure.missingIPA }
        running = true
        // Reserve the shared busy slot so AppsStore operations cannot start meanwhile.
        store?.busy = personalText("Signing with certificate", "عم نوقّع بالشهادة")
        let operation = MirsaOperationProgress.shared.begin(appID: nil, phase: .signing)
        var outcome: MirsaCompletionFeedback.Outcome = .failure
        defer {
            running = false
            store?.busy = nil
            MirsaOperationProgress.shared.finish(operation)
            MirsaCompletionFeedback.shared.finish(operationID: operation, outcome: outcome)
        }
        let options = PersonalProjectOptions()
        let material = identity.material
        let pairingPath = PairingController.pairingFilePath()
        let signed = try await Task.detached(priority: .userInitiated) {
            try PersonalCertificateSigner.sign(ipa: input, material: material, pairingPath: pairingPath, options: options)
        }.value
        let exportDir = signed.url.deletingLastPathComponent()
        let kept: URL
        do { kept = try retain(signed.url) }
        catch {
            // Move failed: signed output stays where it is and is still reachable.
            throw Failure.retained(retainedMessage(error, signed.url), signedURL: signed.url)
        }
        let staged: (stage: URL, app: URL)
        do { staged = try stageSignedApp(ipa: kept, in: FileManager.default.temporaryDirectory) }
        catch { throw Failure.retained(retainedMessage(error, kept), signedURL: kept) }
        defer { try? FileManager.default.removeItem(at: staged.stage) }
        // Associate only the validated, actually rewritten bundle ID.
        if let info = try? IPAEditorService.info(in: staged.app),
           let id = info["CFBundleIdentifier"] as? String, IPAEditorService.validBundleID(id) {
            MirsaOperationProgress.shared.associate(operation, appID: id)
        }
        MirsaOperationProgress.shared.update(operation, phase: .installing)
        do {
            let appPath = staged.app.path
            var result = try await Task.detached(priority: .userInitiated) {
                try SideloadService.installSigned(appPath: appPath) { f, stage in
                    // Fraction only from real transfer/install callbacks.
                    let real: Double? = stage == "Installing" ? f : nil
                    Task { @MainActor in MirsaOperationProgress.shared.update(operation, phase: .installing, fraction: real) }
                }
            }.value
            result["profile_verification"] = signed.verification.profile_verification
            result["warnings"] = signed.verification.warnings.map { ["code": $0.code, "message": $0.message] }
            result["device_authorization"] = "checked"
            outcome = .success
            try? FileManager.default.removeItem(at: kept.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: exportDir)
            return result
        } catch {
            throw Failure.retained(retainedMessage(error, kept), signedURL: kept)
        }
    }

    /// Moves the signed IPA to a persistent, backup-excluded folder so a failed
    /// install leaves a reachable file the user can share.
    static func retain(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MirsaSignedExports", isDirectory: true)
        var dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        let target = dir.appendingPathComponent(url.lastPathComponent)
        try fm.moveItem(at: url, to: target)
        return target
    }

    static func retainedMessage(_ error: Error, _ signed: URL) -> String {
        error.localizedDescription + "\n" + MirsaTr.f("signedKept", signed.lastPathComponent)
    }
}

struct CertificateInstallSheet: View {
    let pending: PendingImport
    @ObservedObject var store: AppsStore
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var identities: [PersonalIdentityVault.SavedIdentity] = []
    @State private var loaded = false
    @State private var working = false
    @State private var message: String?
    @State private var retainedURL: URL?
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(personalText("Install with certificate", "تثبيت عبر الشهادة")).font(.title3.bold())
                    Text(personalText("Works only while your certificate and profile are valid and include this device.",
                                      "بيشتغل بس لما تكون الشهادة والبروفايل صالحين وبيشملوا هالجهاز."))
                        .font(.footnote).foregroundStyle(.secondary)
                    if loaded && identities.isEmpty && message == nil {
                        PersonalCertificateView(onSaved: reload)
                    }
                    ForEach(identities) { id in
                        Button { install(id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(id.name).font(.headline)
                                if !id.verification.isVerified {
                                    Text(id.verification.warningText).font(.caption).foregroundStyle(.orange)
                                }
                                Text([id.teamID, id.expiry.map { $0.formatted(date: .abbreviated, time: .omitted) }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain).disabled(working)
                    }
                    if working { ProgressView() }
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
                    if let retainedURL {
                        Button(personalText("Share signed IPA", "مشاركة الـIPA الموقّع")) { sharing = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
            }
            .background(AuroraBackground())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(personalText("Close", "إغلاق")) { dismiss() }.disabled(working) } }
        }
        .environment(\.layoutDirection, .leftToRight)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(working)
        .sheet(isPresented: $sharing) { if let retainedURL { PersonalSignedShare(url: retainedURL) } }
        .task { reload() }
    }

    private func reload() {
        do { identities = try PersonalIdentityVault.savedIdentities(); message = nil }
        catch { identities = []; message = error.localizedDescription }
        loaded = true
    }

    private func install(_ identity: PersonalIdentityVault.SavedIdentity) {
        working = true; message = nil
        Task {
            do {
                let result = try await CertificateInstall.run(input: pending.originalIPA, appID: pending.bundleID,
                                                     identity: identity, store: store)
                working = false
                if let warnings = result["warnings"] as? [[String: String]], !warnings.isEmpty {
                    message = warnings.compactMap { $0["message"] }.joined(separator: "\n")
                    onDone()
                } else { dismiss(); onDone() }
            } catch {
                message = error.localizedDescription
                if case CertificateInstall.Failure.retained(_, let url) = error { retainedURL = url }
                working = false
            }
        }
    }
}
