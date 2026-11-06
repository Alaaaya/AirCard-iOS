import SwiftUI
import UniformTypeIdentifiers

struct PersonalLibraryApp: Codable, Identifiable {
    let id: UUID
    let name: String
    let bundleID: String
    let version: String
    let signed: Bool
    let date: Date
    var filename: String { id.uuidString + ".ipa" }
}

/// Deliberately separate from AppsStore, DownloadsLibrary, Apple ID and container.
@MainActor
final class PersonalAppsLibrary: ObservableObject {
    static let shared = PersonalAppsLibrary()
    @Published private(set) var apps: [PersonalLibraryApp] = []
    @Published private(set) var loadError: String?
    private let root: URL
    private let index: URL
    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MirsaPersonalApps", isDirectory: true)
        index = root.appendingPathComponent("library.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            var url = root
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            if FileManager.default.fileExists(atPath: index.path) {
                apps = try JSONDecoder().decode([PersonalLibraryApp].self, from: Data(contentsOf: index))
            }
        } catch { loadError = error.localizedDescription }
    }
    func url(_ app: PersonalLibraryApp) -> URL { root.appendingPathComponent(app.filename) }
    func add(_ input: URL, signed: Bool) async throws {
        // Never overwrite an unreadable index with a partial library.
        guard loadError == nil else { throw SideloadError.message("Personal library could not be opened. Unlock your device and reopen Mirsa.") }
        let destination = root
        let app = try await Task.detached(priority: .userInitiated) {
            let access = input.startAccessingSecurityScopedResource()
            defer { if access { input.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            let size = try input.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true, let bytes = size.fileSize, bytes > 0, bytes <= 512 * 1024 * 1024 else {
                throw SideloadError.message("Choose an IPA smaller than 512 MB.")
            }
            let stage = fm.temporaryDirectory.appendingPathComponent("personal-library-\(UUID().uuidString)")
            try fm.createDirectory(at: stage, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            defer { try? fm.removeItem(at: stage) }
            let snapshot = stage.appendingPathComponent("Input.ipa")
            try fm.copyItem(at: input, to: snapshot)
            let extracted = stage.appendingPathComponent("archive")
            try IPAEditorService.run("extract", input: snapshot, output: extracted)
            let bundle = try IPAEditorService.app(in: extracted)
            let info = try IPAEditorService.info(in: bundle)
            guard let bundleID = info["CFBundleIdentifier"] as? String, IPAEditorService.validBundleID(bundleID) else {
                throw SideloadError.message("IPA has no valid bundle identifier.")
            }
            let item = PersonalLibraryApp(id: UUID(),
                name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID,
                bundleID: bundleID, version: info["CFBundleShortVersionString"] as? String ?? "—",
                signed: signed, date: Date())
            let target = destination.appendingPathComponent(item.filename)
            try fm.copyItem(at: snapshot, to: target)
            do { try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path) }
            catch { try? fm.removeItem(at: target); throw error }
            return item
        }.value
        let updated = [app] + apps
        do {
            try JSONEncoder().encode(updated).write(to: index, options: [.atomic, .completeFileProtection])
            apps = updated
        } catch { try? FileManager.default.removeItem(at: url(app)); throw error }
    }
}

struct PersonalAppsHub: View {
    @StateObject private var library = PersonalAppsLibrary.shared
    @State private var importing = false
    @State private var busy = false
    @State private var message: String?
    @State private var selected: PersonalLibraryApp?
    @State private var showSigning = false
    @State private var sharing: PersonalLibraryApp?
    private func text(_ en: String, _ ar: String) -> String { L.isArabic ? ar : en }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(text("Personal Apps", "لوحة التطبيقات")).font(.largeTitle.bold())
                    Text(text("Your own library, separate from Apple ID and Container apps.",
                              "مكتبتك الخاصة، منفصلة عن تطبيقات Apple ID والحاوية."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { selected = nil; showSigning = true } label: {
                        HStack {
                            Image(systemName: "signature").font(.title2)
                            Text(text("Sign apps with a certificate", "توقيع التطبيقات بشهادة")).font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.padding(18).appsGlass(cornerRadius: 24)
                    }.buttonStyle(.plain)
                    HStack {
                        Text(text("My apps", "تطبيقاتي")).font(.title2.bold())
                        Spacer()
                        Button { importing = true } label: {
                            Label(text("Import IPA", "استيراد IPA"), systemImage: "plus")
                        }.disabled(busy || library.loadError != nil)
                    }
                    if busy { ProgressView() }
                    if library.apps.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up").font(.largeTitle)
                            Text(text("Your personal library starts here", "مكتبتك الخاصة بتبدأ هون")).font(.headline)
                            Text(text("Import an IPA or sign one with your certificate. Nothing is installed automatically.",
                                      "استورد IPA أو وقّعه بشهادتك. ما بينثبت شي تلقائياً."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(24).appsGlass()
                    }
                    ForEach(library.apps) { app in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Image(systemName: app.signed ? "checkmark.seal.fill" : "app.dashed")
                                    .font(.title).foregroundStyle(app.signed ? Color.green : Color.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name).font(.headline)
                                    Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text("\(app.version) · " + (app.signed ? text("Signed locally", "موقّع محلياً") : text("Imported", "مستورد")))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            HStack {
                                Button(text("Sign", "توقيع")) { selected = app; showSigning = true }
                                Spacer()
                                Button { sharing = app } label: {
                                    Label(text("Export", "تصدير"), systemImage: "square.and.arrow.up")
                                }
                            }
                        }.padding(18).appsGlass(cornerRadius: 24)
                    }
                    if let error = library.loadError ?? message {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(20).padding(.bottom, 120)
            }.scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .leftToRight)
        .sheet(isPresented: $importing) {
            DocumentPickerView(allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { url in
                busy = true; message = nil
                Task {
                    do { try await library.add(url, signed: false) }
                    catch { message = error.localizedDescription }
                    busy = false
                }
            }
        }
        .sheet(isPresented: $showSigning) {
            NavigationStack {
                ScrollView {
                    PersonalCertificateView(initialIPA: selected.map { library.url($0) }).padding(20)
                }.background(AuroraBackground())
                .toolbar { ToolbarItem(placement: .topBarLeading) {
                    Button(text("Back", "رجوع")) { showSigning = false }
                } }
            }.preferredColorScheme(.dark).environment(\.layoutDirection, .leftToRight)
        }
        .sheet(item: $sharing) { app in
            PersonalLibraryShare(url: library.url(app))
        }
    }
}

private struct PersonalLibraryShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
