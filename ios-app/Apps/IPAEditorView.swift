import SwiftUI
import UniformTypeIdentifiers
import ImageIO

private func editorText(_ english: String, _ arabic: String) -> String { L.isArabic ? arabic : english }

struct IPAEditorView: View {
    let pending: PendingImport
    @ObservedObject var store: AppsStore
    @ObservedObject private var library = IPATweakLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var options: IPAEditOptions
    @State private var showLibrary = false
    @State private var chooseIcon = false
    @State private var changeBundleID = false
    @State private var trustsTweaks = false
    @State private var saving = false
    @State private var failure: String?

    init(pending: PendingImport, store: AppsStore) {
        self.pending = pending
        self.store = store
        let original = (try? IPAEditorService.info(in: pending.workDir.appendingPathComponent("x/Payload")
            .appendingPathComponent(pending.extractedApp.lastPathComponent))) ?? [:]
        let initial = pending.editOptions ?? IPAEditOptions(displayName: pending.name, version: pending.version,
                                                           bundleID: pending.bundleID,
                                                           minimumVersion: original["MinimumOSVersion"] as? String ?? "")
        _options = State(initialValue: initial)
        _changeBundleID = State(initialValue: initial.bundleID != (original["CFBundleIdentifier"] as? String ?? pending.bundleID))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        identityPanel
                        minimumPanel
                        tweaksPanel
                        Text(editorText("Edits are saved into the IPA used for this installation and future refreshes. The source download stays unchanged.",
                                        "التعديلات بتنحفظ بملف التثبيت والتجديد. ملف التنزيل الأصلي ما بيتغير."))
                            .font(.footnote).foregroundStyle(.white.opacity(0.55))
                        if let failure {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        Button {
                            Task { await apply() }
                        } label: {
                            HStack {
                                if saving { ProgressView().tint(.white) }
                                Label(editorText("Save IPA edits", "احفظ تعديلات التطبيق"), systemImage: "checkmark.seal.fill")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity).padding(16)
                            .appsGlass(cornerRadius: 18, tint: .purple)
                        }
                        .buttonStyle(.plain)
                        .disabled(saving || library.importing || (!options.tweakIDs.isEmpty && !trustsTweaks))
                    }
                    .padding(20)
                }
            }
            .navigationTitle(editorText("Edit IPA", "تعديل التطبيق"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editorText("Cancel", "إلغاء")) { dismiss() }.disabled(saving)
                }
            }
            .sheet(isPresented: $showLibrary) {
                IPATweakLibraryView()
            }
            .fileImporter(isPresented: $chooseIcon, allowedContentTypes: [.png, .jpeg], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                    guard size <= 16 * 1024 * 1024 else { throw SideloadError.message("Icon exceeds 16 MiB.") }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                          let h = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                          w.doubleValue > 0, h.doubleValue > 0, w.doubleValue * h.doubleValue <= 16_777_216,
                          let image = UIImage(data: data), let png = image.pngData() else {
                        throw SideloadError.message("Choose an image up to 4096 × 4096 pixels.")
                    }
                    options.iconPNG = png
                    failure = nil
                } catch { failure = error.localizedDescription }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(saving)
    }

    private var identityPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(editorText("App identity", "اسم وشكل التطبيق"), systemImage: "app.badge")
                .font(.headline)
            HStack(spacing: 14) {
                Group {
                    if let data = options.iconPNG, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if let image = pending.icon {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else { Image(systemName: "app.fill").resizable().scaledToFit().padding(14) }
                }
                .frame(width: 66, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 8) {
                    Button(editorText("Choose icon from Files", "اختار أيقونة من الملفات")) { chooseIcon = true }
                    if options.iconPNG != nil {
                        Button(editorText("Use original icon", "رجّع الأيقونة الأصلية")) { options.iconPNG = nil }
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 0)
            }
            field(editorText("Display name", "اسم التطبيق"), text: $options.displayName)
            field(editorText("Version", "الإصدار"), text: $options.version)
            Toggle(editorText("Change bundle identifier", "غيّر معرّف التطبيق"), isOn: $changeBundleID)
                .tint(.purple).font(.subheadline)
                .onChange(of: changeBundleID) { enabled in
                    if !enabled {
                        let baseline = pending.workDir.appendingPathComponent("x/Payload").appendingPathComponent(pending.extractedApp.lastPathComponent)
                        options.bundleID = (try? IPAEditorService.info(in: baseline)["CFBundleIdentifier"] as? String) ?? pending.bundleID
                    }
                }
            if changeBundleID {
                field("com.example.app", text: $options.bundleID)
                Text(editorText("Changing the ID can break app groups, keychain sharing, notifications, extensions or login. It creates a separate app. Entitlements are not automatically repaired.",
                                "تغيير المعرّف ممكن يعطّل الإشعارات والإضافات وتسجيل الدخول ومشاركة البيانات. بيصير تطبيق منفصل، والصلاحيات ما بتتصلّح لحالها."))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(18).appsGlass(cornerRadius: 22)
    }

    private var minimumPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(editorText("Minimum iOS version", "أقل إصدار iOS"), systemImage: "iphone")
                .font(.headline)
            Picker(editorText("Minimum iOS", "أقل إصدار"), selection: $options.minimumOS) {
                Text(editorText("Keep", "خليها")).tag(IPAMinimumOS.keep)
                Text(editorText("Lower", "خفّضها")).tag(IPAMinimumOS.lower)
                Text(editorText("Remove", "احذفها")).tag(IPAMinimumOS.remove)
            }
            .pickerStyle(.segmented)
            if options.minimumOS == .lower {
                field("15.0", text: $options.minimumVersion)
                    .keyboardType(.decimalPad)
            }
            Text(editorText("Changes the main Info.plist only. It cannot add missing iOS APIs or lower Mach-O deployment targets; incompatible apps may still fail to launch.",
                            "بيغيّر شرط الإصدار بملف التطبيق الأساسي بس. ما بيضيف ميزات iOS الناقصة ولا بيغيّر متطلبات الملفات التنفيذية، وممكن التطبيق ما يشتغل."))
                .font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .padding(18).appsGlass(cornerRadius: 22)
    }

    private var tweaksPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(editorText("Inject tweaks", "إضافة تويكس"), systemImage: "puzzlepiece.extension.fill").font(.headline)
                Spacer()
                Button(editorText("Library", "المكتبة")) { showLibrary = true }.font(.subheadline)
            }
            if library.items.isEmpty {
                Text(editorText("Import your own .dylib, .deb or .framework from the library.",
                                "ضيف ملفاتك .dylib أو .deb أو .framework من المكتبة."))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }
            ForEach(library.items) { item in
                Button {
                    if options.tweakIDs.contains(item.id) { options.tweakIDs.remove(item.id) }
                    else { options.tweakIDs.insert(item.id) }
                    trustsTweaks = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: options.tweakIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(options.tweakIDs.contains(item.id) ? .purple : .white.opacity(0.5))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                            Text(editorText("\(item.roots.count) code file(s)", "\(item.roots.count) ملفات كود"))
                                .font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !options.tweakIDs.isEmpty {
                Toggle(editorText("I trust the selected code", "أنا واثق من هالملفات"), isOn: $trustsTweaks)
                    .tint(.purple).font(.subheadline)
            }
            Text(editorText("Injected code runs inside the installed app and can read its data. Only thin arm64, unencrypted binaries with spare header space are supported. Jailbreak-only tweaks may not work. Missing hook libraries fail safely; no CydiaSubstrate or ElleKit is bundled.",
                            "التويك بيشتغل جوّا التطبيق وبيقدر يقرأ بياناته. الدعم لملفات arm64 غير مشفّرة وفيها مساحة بالهيدر. تويكس الجيلبريك مو مضمونة، والمكتبات الناقصة بتوقف العملية بأمان. ما منرفق CydiaSubstrate أو ElleKit."))
                .font(.caption).foregroundStyle(.orange.opacity(0.9))
        }
        .padding(18).appsGlass(cornerRadius: 22)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.65))
            TextField(title, text: text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @MainActor private func apply() async {
        saving = true; failure = nil
        defer { saving = false }
        do {
            let urls = try library.urls(for: options.tweakIDs)
            try await store.editPending(options, libraries: urls)
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}

struct IPATweakLibraryView: View {
    @ObservedObject private var library = IPATweakLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showFiles = false
    @State private var remoteURL = ""
    @State private var failure: String?
    @State private var deleting: IPATweak?

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(editorText("Your code, your library", "ملفاتك ومكتبتك"))
                            .font(.title2.bold())
                        Text(editorText("Files are kept on this device. Imports are not executed. Only select code from developers you trust.",
                                        "الملفات بتنحفظ على هالجهاز وما بتشتغل وقت الإضافة. اختار ملفات من مطوّرين بتوثق فيهم."))
                            .font(.subheadline).foregroundStyle(.white.opacity(0.65))
                        Button { showFiles = true } label: {
                            Label(editorText("Import from Files", "إضافة من الملفات"), systemImage: "folder.badge.plus")
                                .font(.headline).frame(maxWidth: .infinity).padding(16)
                                .appsGlass(cornerRadius: 18, tint: .purple)
                        }
                        .buttonStyle(.plain).disabled(library.importing)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(editorText("Direct HTTPS download", "رابط تنزيل HTTPS مباشر")).font(.subheadline.weight(.medium))
                            TextField("https://example.com/tweak.deb", text: $remoteURL)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            Button(editorText("Download into library", "نزّل عالمكتبة")) {
                                Task {
                                    failure = nil
                                    do { try await library.addURL(remoteURL); remoteURL = "" }
                                    catch { failure = error.localizedDescription }
                                }
                            }
                            .disabled(library.importing || remoteURL.isEmpty)
                        }
                        .padding(16).appsGlass(cornerRadius: 18)
                        if library.importing {
                            HStack { ProgressView().tint(.white); Text(editorText("Importing…", "عم نضيف الملف…")) }
                                .font(.subheadline)
                        }
                        if let failure {
                            Text(failure).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        ForEach(library.items) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "puzzlepiece.extension.fill").font(.title2).foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.name).font(.headline)
                                    Text(item.roots.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                                    if item.packageOnlyCode {
                                        Text(editorText("Debian code only. Scripts, filters and resources outside frameworks are not installed.",
                                                        "كود الحزمة بس. السكربتات والفلاتر والموارد خارج الفريمورك ما بتنثبت."))
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Spacer(minLength: 4)
                                Button(role: .destructive) { deleting = item } label: {
                                    Image(systemName: "trash").padding(6)
                                }
                                .disabled(library.importing)
                            }
                            .padding(16).appsGlass(cornerRadius: 18)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(editorText("Tweak library", "مكتبة التويكس"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editorText("Done", "خلص")) { dismiss() }.disabled(library.importing)
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data, .folder, .package], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    Task {
                        failure = nil
                        do { try await library.addFile(url) } catch { failure = error.localizedDescription }
                    }
                } catch { failure = error.localizedDescription }
            }
            .confirmationDialog(editorText("Remove from library?", "احذف الملف من المكتبة؟"),
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button(editorText("Remove", "حذف"), role: .destructive) {
                    if let item = deleting {
                        do { try library.delete(item) } catch { failure = error.localizedDescription }
                    }
                    deleting = nil
                }
            } message: {
                Text(editorText("Already edited or installed IPAs are unchanged.", "التطبيقات المعدّلة أو المثبّتة ما بتتأثر."))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(library.importing)
    }
}
