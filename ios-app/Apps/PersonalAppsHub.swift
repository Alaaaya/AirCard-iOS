import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct PersonalLibraryApp: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var bundleID: String
    var version: String
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
    private var triedIcons = Set<UUID>()
    private let iconCache = NSCache<NSString, UIImage>()
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
    func iconURL(_ app: PersonalLibraryApp) -> URL { root.appendingPathComponent("icon-\(app.id.uuidString).png") }
    func draftURL(_ app: PersonalLibraryApp) -> URL { root.appendingPathComponent("project-\(app.id.uuidString).json") }

    private func persist(_ list: [PersonalLibraryApp]) throws {
        guard loadError == nil else { throw SideloadError.message(personalText("Personal library could not be opened. Unlock your device and reopen Mirsa.", "المكتبة ما انفتحت. افتح قفل الجهاز وافتح ميرسا من جديد.")) }
        try JSONEncoder().encode(list).write(to: index, options: [.atomic, .completeFileProtection])
        apps = list
    }
    func delete(_ app: PersonalLibraryApp) throws {
        try persist(apps.filter { $0.id != app.id })
        let fm = FileManager.default
        for u in [url(app), iconURL(app), draftURL(app)] { try? fm.removeItem(at: u) }
        iconCache.removeObject(forKey: app.id.uuidString as NSString)
    }

    /// Cached icon. Never decodes anything bigger than the 180px PNG we wrote ourselves.
    func icon(for app: PersonalLibraryApp) -> UIImage? {
        let key = app.id.uuidString as NSString
        if let hit = iconCache.object(forKey: key) { return hit }
        guard let image = UIImage(contentsOfFile: iconURL(app).path) else { return nil }
        iconCache.setObject(image, forKey: key)
        return image
    }
    /// Legacy apps imported before icons were stored. Tried once per launch, bounded to 512 MB.
    func ensureIcon(for app: PersonalLibraryApp) async -> UIImage? {
        if let image = icon(for: app) { return image }
        guard !triedIcons.contains(app.id) else { return nil }
        triedIcons.insert(app.id)
        let source = url(app), target = iconURL(app)
        let ok: Bool = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 512 * 1024 * 1024 else { return false }
            let stage = fm.temporaryDirectory.appendingPathComponent("personal-icon-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: stage) }
            do {
                try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                try IPAEditorService.run("extract", input: source, output: stage.appendingPathComponent("a"))
                let bundle = try IPAEditorService.app(in: stage.appendingPathComponent("a"))
                let info = try IPAEditorService.info(in: bundle)
                guard let png = Self.iconPNG(bundle: bundle, info: info) else { return false }
                try png.write(to: target, options: [.atomic, .completeFileProtection])
                return true
            } catch { return false }
        }.value
        return ok ? icon(for: app) : nil
    }
    nonisolated static func iconPNG(bundle: URL, info: [String: Any]) -> Data? {
        var names = Set<String>()
        func collect(_ dict: [String: Any]?) {
            guard let primary = dict?["CFBundlePrimaryIcon"] as? [String: Any] else { return }
            (primary["CFBundleIconFiles"] as? [String])?.forEach { names.insert($0) }
        }
        collect(info["CFBundleIcons"] as? [String: Any])
        collect(info["CFBundleIcons~ipad"] as? [String: Any])
        (info["CFBundleIconFiles"] as? [String])?.forEach { names.insert($0) }
        if let n = info["CFBundleIconFile"] as? String { names.insert(n) }
        // Asset-catalog-only IPAs have no loose PNG. Read their own compiled
        // catalog through Bundle without loading or executing the app binary.
        if let resourceBundle = Bundle(path: bundle.path) {
            var assetNames = names
            for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
                if let dict = info[key] as? [String: Any],
                   let primary = dict["CFBundlePrimaryIcon"] as? [String: Any],
                   let name = primary["CFBundleIconName"] as? String { assetNames.insert(name) }
            }
            if let name = info["CFBundleIconName"] as? String { assetNames.insert(name) }
            for name in assetNames.sorted() {
                if let image = UIImage(named: name, in: resourceBundle, compatibleWith: nil),
                   image.size.width > 0, image.size.height > 0,
                   image.size.width <= 4096, image.size.height <= 4096 {
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    return UIGraphicsImageRenderer(size: CGSize(width: 180, height: 180), format: format).pngData { _ in
                        image.draw(in: CGRect(x: 0, y: 0, width: 180, height: 180))
                    }
                }
            }
        }
        let prefixes = names.map { ($0 as NSString).deletingPathExtension }.filter { !$0.isEmpty }
        guard !prefixes.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
        let best = files.compactMap { f -> (URL, Int)? in
            guard f.pathExtension.lowercased() == "png",
                  prefixes.contains(where: { f.lastPathComponent.hasPrefix($0) }),
                  let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true, let s = v.fileSize, s > 0, s <= 2 * 1024 * 1024 else { return nil }
            return (f, s)
        }.max { $0.1 < $1.1 }
        guard let best, let data = try? Data(contentsOf: best.0),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 180,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let side: CGFloat = 180
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

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
            // Icon is best effort; a missing icon never blocks the import.
            if let png = Self.iconPNG(bundle: bundle, info: info) {
                try? png.write(to: destination.appendingPathComponent("icon-\(item.id.uuidString).png"),
                               options: [.atomic, .completeFileProtection])
            }
            return item
        }.value
        do { try persist([app] + apps) }
        catch {
            try? FileManager.default.removeItem(at: url(app))
            try? FileManager.default.removeItem(at: iconURL(app))
            throw error
        }
    }
}

private struct PersonalAppIcon: View {
    let app: PersonalLibraryApp
    @ObservedObject var library: PersonalAppsLibrary
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(app.name.prefix(1)).uppercased())
                    .font(.title2.bold()).foregroundStyle(Color.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.08))
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .task(id: app.id) {
            image = library.icon(for: app)
            if image == nil { image = await library.ensureIcon(for: app) }
        }
    }
}

struct PersonalAppsHub: View {
    @StateObject private var library = PersonalAppsLibrary.shared
    @State private var importing = false
    @State private var importingURL = false
    @State private var busy = false
    @State private var message: String?
    @State private var detail: PersonalLibraryApp?
    @State private var showCertificates = false
    @State private var sharing: PersonalLibraryApp?
    @State private var deleting: PersonalLibraryApp?
    @AppStorage("mirsa.personal.projects.sort") private var sort = "newest"
    @State private var drafts: [UUID: PersonalProjectDraft] = [:]
    @StateObject private var tweaks = IPATweakLibrary.shared

    private var sortedApps: [PersonalLibraryApp] {
        switch sort {
        case "name": return library.apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "oldest": return library.apps.sorted { $0.date < $1.date }
        default: return library.apps.sorted { $0.date > $1.date }
        }
    }
    private func reloadDrafts() {
        drafts = Dictionary(uniqueKeysWithValues: library.apps.compactMap { app in
            guard let data = try? Data(contentsOf: library.draftURL(app)),
                  let draft = try? JSONDecoder().decode(PersonalProjectDraft.self, from: data) else { return nil }
            return (app.id, draft)
        })
    }
    private func removeTweak(_ id: UUID, from app: PersonalLibraryApp) {
        do {
            let data = try Data(contentsOf: library.draftURL(app))
            var draft = try JSONDecoder().decode(PersonalProjectDraft.self, from: data)
            draft.tweakIDs.removeAll { $0 == id }
            try JSONEncoder().encode(draft).write(to: library.draftURL(app), options: [.atomic, .completeFileProtection])
            drafts[app.id] = draft
        } catch { message = error.localizedDescription }
    }
    private func chip(_ text: String, blue: Bool = false) -> some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(blue ? Color.cyan : Color.white.opacity(0.75))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    private func projectCard(_ app: PersonalLibraryApp) -> some View {
        let draft = drafts[app.id]
        let ids = draft?.tweakIDs ?? []
        let selected = ids.compactMap { id in tweaks.items.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 12) {
            Button { detail = app } label: {
                HStack(spacing: 13) {
                    PersonalAppIcon(app: app, library: library)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(draft?.name.isEmpty == false ? draft!.name : app.name).font(.headline).lineLimit(1)
                        Text(draft?.bundleID.isEmpty == false ? draft!.bundleID : app.bundleID)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button { detail = app } label: { chip("v" + (draft?.version.isEmpty == false ? draft!.version : app.version), blue: true) }
                        .buttonStyle(.plain)
                    ForEach(selected) { item in
                        HStack(spacing: 5) {
                            Button(item.name) { detail = app }.buttonStyle(.plain).lineLimit(1)
                            Button { removeTweak(item.id, from: app) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain).accessibilityLabel(personalText("Remove ", "إزالة ") + item.name)
                        }.font(.caption2).padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    Button { detail = app } label: {
                        chip(personalText("\(ids.count) add-ons", "\(ids.count) المكونات الإضافية"))
                    }.buttonStyle(.plain)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).appsGlass(cornerRadius: 24)
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Menu {
                            Button { importing = true } label: { Label(personalText("From Files", "من الملفات"), systemImage: "folder") }
                            Button { importingURL = true } label: { Label(personalText("From link", "من رابط"), systemImage: "link") }
                        } label: {
                            Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 42, height: 42).appsGlass(cornerRadius: 21)
                        }.disabled(busy || library.loadError != nil)
                        Spacer()
                        Text(personalText("Projects", "المشاريع")).font(.title2.bold())
                        Spacer()
                        Menu {
                            Picker(personalText("Sort projects", "ترتيب المشاريع"), selection: $sort) {
                                Text(personalText("Newest first", "الأحدث أولاً")).tag("newest")
                                Text(personalText("Oldest first", "الأقدم أولاً")).tag("oldest")
                                Text(personalText("Name", "الاسم")).tag("name")
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease").font(.title3).frame(width: 42, height: 42).appsGlass(cornerRadius: 21)
                        }
                    }
                    Button { showCertificates = true } label: {
                        HStack {
                            Image(systemName: "signature").font(.title2)
                            Text(personalText("Signing certificates", "شهادات التوقيع")).font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.padding(18).appsGlass(cornerRadius: 24)
                    }.buttonStyle(.plain)
                    if busy { ProgressView() }
                    if library.apps.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up").font(.largeTitle)
                            Text(personalText("Your personal library starts here", "مكتبتك الخاصة بتبدأ هون")).font(.headline)
                            Text(personalText("Import an IPA, then open it to edit and sign. Nothing is installed automatically.",
                                      "استورد IPA وافتحه لتعدّله وتوقّعه. ما بينثبت شي تلقائياً."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(24).appsGlass()
                    }
                    ForEach(sortedApps) { app in
                        projectCard(app)
                        .contextMenu {
                            Button { detail = app } label: { Label(personalText("Project details", "تفاصيل المشروع"), systemImage: "slider.horizontal.3") }
                            Button { sharing = app } label: { Label(personalText("Export IPA", "تصدير IPA"), systemImage: "square.and.arrow.up") }
                            Button(role: .destructive) { deleting = app } label: { Label(personalText("Delete", "حذف"), systemImage: "trash") }
                        }
                    }
                    if let error = library.loadError ?? message {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(20).padding(.bottom, 120)
            }.scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .leftToRight)
        .task { reloadDrafts() }
        .onChange(of: library.apps) { _ in reloadDrafts() }
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
        .sheet(isPresented: $importingURL) { PersonalURLImportSheet(disabled: library.loadError != nil) { try await library.add($0, signed: false) } }
        .sheet(isPresented: $showCertificates) {
            PersonalCertificateManagerView()
        }
        .sheet(item: $detail, onDismiss: reloadDrafts) { app in
            PersonalProjectDetailView(app: app)
        }
        .sheet(item: $sharing) { app in
            PersonalLibraryShare(url: library.url(app))
        }
        .confirmationDialog(personalText("Delete this app from your personal library?", "حذف هالتطبيق من مكتبتك؟"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { app in
            Button(personalText("Delete", "حذف"), role: .destructive) {
                do { try library.delete(app) } catch { message = error.localizedDescription }
                deleting = nil
            }
        } message: { app in
            Text(app.name)
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
