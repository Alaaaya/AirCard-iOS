import SwiftUI
import UniformTypeIdentifiers

struct PersonalProjectDetailView: View {
    let app: PersonalLibraryApp
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = PersonalAppsLibrary.shared
    @StateObject private var tweaks = IPATweakLibrary.shared
    @State private var draft = PersonalProjectDraft()
    @State private var loaded = false
    @StateObject private var keyboard = MirsaKeyboardVisibility()
    @State private var identities: [PersonalIdentityVault.SavedIdentity] = []
    @State private var selectedID: String?
    @State private var showCertificates = false
    @State private var pickingTweak = false
    @State private var configBusy = false
    @ObservedObject var signing = PersonalSigningOperation.shared
    @State private var consumedResult: UUID?
    private var busy: Bool { configBusy || signing.running }
    @State private var message: String?
    @State private var resultAlert: String?
    @State private var output: URL?
    @State private var sharing = false
    @State private var icon: UIImage?
    @State private var extensionCount: Int?
    @State private var deps: [String]?
    @State private var showDeps = false
    @State private var pickingEntitlements = false
    @StateObject private var draftWriter = PersonalProjectDraftWriter()
    @State private var draftDestination: URL?
    @State private var scrolling = false
    @State private var workspace: ProjectFolderLocation?

    private var configOnly: Bool { selected == nil }
    private var selected: PersonalIdentityVault.SavedIdentity? {
        identities.first { $0.id == selectedID } ?? identities.first
    }
    private func tweak(_ id: UUID) -> IPATweak? { tweaks.items.first { $0.id == id } }

    var body: some View {
        ZStack {
            PersonalProjectBackdrop(paused: keyboard.isVisible || scrolling).equatable()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left").font(.headline).frame(width: 40, height: 40)
                                .appsGlass(cornerRadius: 20)
                        }.buttonStyle(.plain)
                        Spacer()
                        Text(personalText("Project details", "تفاصيل المشروع")).font(.headline)
                        Spacer()
                        Color.clear.frame(width: 40, height: 40)
                    }
                    appCard
                    outputCard
                    tweaksCard
                    settingsCard
                    depsCard
                    certificateCard
                    Button { openBundleFiles() } label: {
                        Label(bundleLoading ? personalText("Reading app…", "عم أقرأ التطبيق…") : personalText("Bundle files", "ملفات التطبيق"), systemImage: "doc.on.doc")
                    }.buttonStyle(.bordered).disabled(bundleLoading)
                    NavigationLink { MirsaTelemetryView(bundleID: app.bundleID) } label: {
                        Label(personalText("Launches & crash logs", "التشغيل وسجلات الأعطال"), systemImage: "waveform.path.ecg")
                    }.buttonStyle(.bordered)
                    Button { openWorkspace() } label: {
                        Label(personalText("Browse workspace folder", "تصفّح مجلد المشروع"), systemImage: "folder")
                    }.buttonStyle(.bordered)
                    if let message { Text(message).font(.footnote).textSelection(.enabled) }
                }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 32)
            }.scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onScrollPhaseChange { _, phase in scrolling = phase != .idle }
        }
        .safeAreaInset(edge: .bottom) {
            if !keyboard.isVisible {
            Button { sign() } label: {
                HStack(spacing: 8) {
                    if let state = signing.state, state.projectID == app.id, state.running {
                        PersonalSigningProgressView(state: state)
                    } else {
                        if configBusy { ProgressView() } else { Image(systemName: "hammer.fill") }
                        Text(configOnly ? personalText("Export configuration only", "تصدير الإعدادات فقط") : personalText("Sign & Install", "توقيع وتثبيت")).fontWeight(.semibold)
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).tint(.green)
            .accessibilityIdentifier("mirsa.project.sign")
            .disabled(busy)
            .padding(.horizontal, 20).padding(.bottom, 12).padding(.top, 12)
            .background(.ultraThinMaterial)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .leftToRight)
        .sheet(isPresented: $showCertificates, onDismiss: reloadIdentities) { PersonalCertificateManagerView() }
        .sheet(isPresented: $pickingTweak) {
            DocumentPickerView(allowedContentTypes: ["dylib", "deb", "framework"].compactMap { UTType(filenameExtension: $0) } + [.data]) { url in
                Task {
                    do {
                        try await tweaks.addFile(url)
                        if let first = tweaks.items.first, !draft.tweakIDs.contains(first.id) { draft.tweakIDs.append(first.id) }
                    } catch { message = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: $pickingEntitlements) {
            DocumentPickerView(allowedContentTypes: [.propertyList, .xml, .data]) { url in
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024,
                      let data = try? Data(contentsOf: url),
                      (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
                    message = personalText("Invalid or too large entitlements file (max 64 KB plist).", "ملف Entitlements غير صالح أو كبير (الحد 64KB)."); return
                }
                draft.customEntitlements = data; draft.customEntitlementsName = url.lastPathComponent
            }
        }
        .sheet(isPresented: $sharing, onDismiss: cleanOutput) {
            if let output { PersonalSignedShare(url: output) }
        }
        .sheet(isPresented: Binding(get: { bundleManager != nil }, set: { if !$0 { bundleManager = nil } })) {
            if let manager = bundleManager {
                NavigationStack {
                    BundleFileBrowserView(manager: manager, onChange: { draft.bundleOverlay = manager.overlay.isEmpty ? nil : manager.overlay })
                }
            }
        }
        .sheet(item: $workspace) { location in
            PersonalProjectFolderBrowser(root: location.url, title: draft.name)
        }
        .alert(personalText("Result", "النتيجة"), isPresented: Binding(get: { resultAlert != nil }, set: { if !$0 { resultAlert = nil } })) {
            Button(personalText("OK", "تمام")) { resultAlert = nil }
        } message: { Text(resultAlert ?? "") }
        .task { await load(); await inspect(); consumeSigningResult() }
        .onChange(of: signing.state?.running) { _ in consumeSigningResult() }
        .onChange(of: draft) { _ in if loaded, let destination = draftDestination { draftWriter.schedule(draft, to: destination) } }
        .onChange(of: scenePhase) { phase in if phase != .active { draftWriter.flush() } }
        .onDisappear { draftWriter.flush(); if !sharing { cleanOutput() } }
    }

    private var appCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let icon { Image(uiImage: icon).resizable().scaledToFill() }
                else { Image(systemName: "app.dashed").font(.title).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.08)) }
            }.frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                field(personalText("Name", "الاسم"), $draft.name)
                field(personalText("Bundle ID", "معرّف التطبيق"), $draft.bundleID, mono: true)
                field(personalText("Version", "الإصدار"), $draft.version)
                field(personalText("Workspace note", "ملاحظة المشروع"), Binding(get: { draft.workspaceNote ?? "" }, set: { draft.workspaceNote = String($0.prefix(300)) }))
                HStack(spacing: 8) {
                    chip("puzzlepiece.extension", extensionCount.map { "\($0) " + personalText("extensions", "إضافات") } ?? "…")
                    chip("arrow.triangle.branch", personalText("Main executable", "الملف الرئيسي"))
                }
            }
        }.padding(16).appsGlass(cornerRadius: 24)
    }
    private func chip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.caption2.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    private func field(_ title: String, _ binding: Binding<String>, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField(title, text: binding).font(mono ? .footnote.monospaced() : .subheadline)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
        }
    }
    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(personalText("Output file name", "اسم ملف الإخراج"), systemImage: "doc.fill").font(.subheadline.weight(.semibold))
            HStack {
                TextField("Mirsa-Signed", text: $draft.outputFilename).autocorrectionDisabled().textInputAutocapitalization(.never)
            }.padding(12).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Picker("", selection: Binding(get: { draft.exportExtension ?? "ipa" }, set: { draft.exportExtension = $0 })) {
                Text("IPA").tag("ipa"); Text("TIPA").tag("tipa")
            }.pickerStyle(.segmented)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).appsGlass(cornerRadius: 24)
    }
    private var tweaksCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(personalText("Injected tweaks", "الإضافات المحقونة"), systemImage: "puzzlepiece.extension.fill").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button { pickingTweak = true } label: { Label(personalText("Import file", "استيراد ملف"), systemImage: "folder") }
                    let rest = tweaks.items.filter { !draft.tweakIDs.contains($0.id) }
                    ForEach(rest) { item in
                        Button(item.name) { draft.tweakIDs.append(item.id) }
                    }
                } label: { Label(personalText("Add", "إضافة"), systemImage: "plus") }
            }
            let ids = draft.tweakIDs.filter { tweak($0) != nil }
            let applied = Set(draft.appliedTweakIDs ?? [])
            let added = ids.filter { !applied.contains($0) }.count
            let removed = applied.filter { !ids.contains($0) }.count
            if added + removed > 0 {
                Label(personalText("Pending changes: \(added) added, \(removed) removed. Applied on next export.", "تغييرات معلّقة: أُضيف \(added)، حُذف \(removed). بتنطبق عند التصدير."), systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(.yellow)
            }
            if ids.isEmpty {
                Text(personalText("No tweaks. Add .dylib, .deb or .framework files.", "ما في إضافات. ضيف ملفات .dylib أو .deb أو .framework."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            let comps = components()
            ForEach(Array(comps.enumerated()), id: \.element.id) { index, comp in
                HStack(spacing: 10) {
                    Button { removeComponent(comp) } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comp.title).font(.subheadline).lineLimit(1)
                        if comp.subtitle != comp.title { Text(comp.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        Menu {
                            Button { draft.directInjection = true } label: { Label(personalText("Via main executable", "عبر الملف التنفيذي الرئيسي"), systemImage: loaderOn ? "circle" : "checkmark") }
                            Button { draft.directInjection = false } label: { Label(personalText("Via LoadControl", "عبر LoadControl"), systemImage: loaderOn ? "checkmark" : "circle") }
                        } label: {
                            Text((loaderOn ? personalText("Via LoadControl", "عبر LoadControl") : personalText("Via main executable", "عبر الملف التنفيذي الرئيسي")) + " ▾").font(.caption2).foregroundStyle(.secondary)
                        }
                        targetMenu(comp)
                    }
                    Spacer()
                    ShareLink(item: comp.url) { Image(systemName: "square.and.arrow.up") }
                    Button { moveComponent(comp.id, -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                    Button { moveComponent(comp.id, 1) } label: { Image(systemName: "arrow.down") }.disabled(index == comps.count - 1)
                }.buttonStyle(.plain).padding(10).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }.padding(16).appsGlass(cornerRadius: 24)
    }
    struct TweakComponent { let id: String; let tweakID: UUID; let title: String; let subtitle: String; let url: URL }
    /// Every selected package expands to one component per dylib/framework root (stable id uuid:path).
    /// Order = persisted componentOrder (still valid) then new components in package order. Excluded ones are hidden.
    private func components() -> [TweakComponent] {
        let excluded = Set(draft.excludedRoots ?? [])
        var all: [TweakComponent] = []
        for id in draft.tweakIDs {
            guard let item = tweak(id) else { continue }
            for root in item.roots {
                let cid = IPATweakLibrary.componentID(item, root)
                if excluded.contains(cid) { continue }
                let url = IPATweakLibrary.root.appendingPathComponent(item.id.uuidString).appendingPathComponent(root)
                all.append(TweakComponent(id: cid, tweakID: id, title: (root as NSString).lastPathComponent, subtitle: item.name, url: url))
            }
        }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let saved = (draft.componentOrder ?? []).compactMap { byID[$0] }
        let savedSet = Set(saved.map(\.id))
        var seen = Set<String>()
        return (saved + all.filter { !savedSet.contains($0.id) }).filter { seen.insert($0.id).inserted }
    }
    private func moveComponent(_ id: String, _ delta: Int) {
        var order = components().map(\.id)
        guard let i = order.firstIndex(of: id), order.indices.contains(i + delta) else { return }
        order.swapAt(i, i + delta)
        draft.componentOrder = order
    }
    private func removeComponent(_ comp: TweakComponent) {
        var list = draft.excludedRoots ?? []
        list.append(comp.id)
        draft.excludedRoots = list
        draft.componentOrder = (draft.componentOrder ?? []).filter { $0 != comp.id }
        if !components().contains(where: { $0.tweakID == comp.tweakID }) {
            draft.tweakIDs.removeAll { $0 == comp.tweakID }
            draft.excludedRoots = (draft.excludedRoots ?? []).filter { !$0.hasPrefix(comp.tweakID.uuidString + ":") }
        }
    }
    @State private var bundleManager: BundleFileManager?
    @State private var bundleLoading = false
    private var bundleDirs: (original: URL, staging: URL) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MirsaBundleFiles/\(app.id.uuidString)", isDirectory: true)
        return (base.appendingPathComponent("original", isDirectory: true), base.appendingPathComponent("staging", isDirectory: true))
    }
    /// Extracts the project's IPA once (original stays untouched) and opens the staged file manager.
    private func openBundleFiles() {
        guard !bundleLoading else { return }
        bundleLoading = true
        let input = library.url(app); let dirs = bundleDirs; let overlay = draft.bundleOverlay ?? BundleOverlay()
        Task {
            let result: BundleFileManager? = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                do {
                    if !fm.fileExists(atPath: dirs.original.path) {
                        let tmp = dirs.original.deletingLastPathComponent().appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
                        try fm.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try IPAEditorService.run("extract", input: input, output: tmp)
                        try fm.moveItem(at: try IPAEditorService.app(in: tmp), to: dirs.original)
                        try? fm.removeItem(at: tmp)
                    }
                    try fm.createDirectory(at: dirs.staging, withIntermediateDirectories: true)
                    return try BundleFileManager(root: dirs.original, stagingDirectory: dirs.staging, overlay: overlay)
                } catch { return nil }
            }.value
            bundleLoading = false
            if let result { bundleManager = result } else { message = personalText("Could not read the app files.", "ما قدرت أقرأ ملفات التطبيق.") }
        }
    }
    @State private var targetList: [(id: String, kind: String, label: String)] = []
    @State private var targetsLoading = false
    private func mainTarget() -> String? { targetList.first { $0.kind == "main" }?.id }
    @ViewBuilder private func targetMenu(_ comp: TweakComponent) -> some View {
        let current = draft.tweakTargets?[comp.id]
        let shown = targetList.first { $0.id == current }?.label ?? personalText("Main app", "التطبيق الرئيسي")
        Menu {
            if targetList.isEmpty {
                Button { loadTargets() } label: { Label(targetsLoading ? personalText("Reading app…", "عم أقرأ التطبيق…") : personalText("Load targets", "تحميل الأهداف"), systemImage: "arrow.down.circle") }
            }
            ForEach(targetList, id: \.id) { t in
                Button { setTarget(comp.id, t) } label: {
                    Label(t.label + " (" + t.kind + ")", systemImage: (current == t.id || (current == nil && t.kind == "main")) ? "checkmark" : "circle")
                }.disabled(loaderOn && t.kind != "main")
            }
        } label: { Text(personalText("Target: ", "الهدف: ") + shown + " ▾").font(.caption2).foregroundStyle(.secondary) }
    }
    private func setTarget(_ cid: String, _ t: (id: String, kind: String, label: String)) {
        var m = draft.tweakTargets ?? [:]
        if t.kind == "main" { m.removeValue(forKey: cid) } else { m[cid] = t.id }
        draft.tweakTargets = m
    }
    private func loadTargets() {
        guard !targetsLoading else { return }
        targetsLoading = true
        let input = library.url(app)
        Task {
            let result: [(id: String, kind: String, label: String)]? = await Task.detached(priority: .userInitiated) {
                let stage = FileManager.default.temporaryDirectory.appendingPathComponent("targets-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: stage) }
                do {
                    try IPAEditorService.run("extract", input: input, output: stage)
                    return try IPAEditorService.targets(app: IPAEditorService.app(in: stage), scratch: stage)
                } catch { return nil }
            }.value
            targetsLoading = false
            if let result { targetList = result } else { message = personalText("Could not read the app targets.", "ما قدرت أقرأ أهداف التطبيق.") }
        }
    }
    private var loaderOn: Bool { draft.directInjection == false }
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(personalText("Project settings", "إعدادات المشروع"), systemImage: "gearshape.fill").font(.subheadline.weight(.semibold))
            toggle(personalText("Enable Files access", "تمكين الوصول إلى الملفات"), personalText("Shows app documents in Files.", "بيظهر ملفات التطبيق بتطبيق الملفات."), $draft.fileSharing)
            toggle(personalText("Remove URL schemes", "إزالة مخططات URL"), personalText("Deletes the app's custom URL schemes.", "بيحذف مخططات URL تبع التطبيق."), $draft.removeURLSchemes)
            toggle(personalText("Remove old embedded profile", "إزالة البروفايل المضمّن القديم"), personalText("Only the old one. Signing still embeds your new profile.", "القديم بس. التوقيع لسا بيضمّن البروفايل الجديد تبعك."), $draft.removeEmbeddedProfile)
            toggle(personalText("Remove extensions", "إزالة الإضافات المضمّنة"), personalText("Removes PlugIns before signing.", "بيحذف مجلد PlugIns قبل التوقيع."), Binding(get: { draft.removeExtensions ?? false }, set: { draft.removeExtensions = $0 }))
            toggle(personalText("Remove App Clips", "إزالة App Clips"), personalText("Removes AppClips before signing.", "بيحذف مجلد AppClips قبل التوقيع."), Binding(get: { draft.removeAppClips ?? false }, set: { draft.removeAppClips = $0 }))
            toggle(personalText("Remove Watch app", "إزالة تطبيق الساعة"), personalText("Deletes the Watch folder before signing.", "بيحذف مجلد الساعة قبل التوقيع."), $draft.removeWatchApp)
            toggle(personalText("Fix white/blank icon", "إصلاح الأيقونة البيضاء"), personalText("Flattens transparent icon PNGs onto black.", "بيحوّل أيقونات PNG الشفافة لخلفية سودا."), Binding(get: { draft.fixWhiteIcon ?? false }, set: { draft.fixWhiteIcon = $0 }))
            toggle(personalText("Fix dark icon (iOS 18)", "إصلاح الأيقونة الداكنة (iOS 18)"), personalText("Unavailable: needs Assets.car rewriting.", "غير متاح: بدو تعديل Assets.car."), .constant(false)).disabled(true).opacity(0.5)
            toggle(personalText("Direct injection (main executable)", "حقن مباشر بالملف الرئيسي"), personalText("Off uses Mirsa's own ordered loader (arm64 only, untested on device).", "إذا طفيته بيستخدم محمّل ميرسا المرتب (arm64 بس، ما انجرّب عالجهاز)."), Binding(get: { !loaderOn }, set: { draft.directInjection = $0 }))
            toggle(personalText("New tweaks first", "الإضافات الجديدة أولاً"), personalText("Injected libraries load before the app's own.", "المكتبات المحقونة بتتحمّل قبل مكتبات التطبيق."), Binding(get: { draft.newTweaksFirst ?? false }, set: { draft.newTweaksFirst = $0 }))
            HStack {
                Text(personalText("Game Mode", "وضع الألعاب")).font(.subheadline)
                Spacer()
                Picker("", selection: Binding(get: { draft.gameMode ?? .keep }, set: { draft.gameMode = $0 })) {
                    Text(personalText("Keep", "إبقاء")).tag(PersonalGameMode.keep)
                    Text(personalText("On", "تشغيل")).tag(PersonalGameMode.on)
                    Text(personalText("Off", "إيقاف")).tag(PersonalGameMode.off)
                }.pickerStyle(.menu)
            }
            HStack {
                Text(personalText("Minimum iOS", "أدنى إصدار iOS")).font(.subheadline)
                Spacer()
                Picker("", selection: $draft.minimumOS) {
                    Text(personalText("Keep", "إبقاء")).tag("")
                    ForEach(["12.0", "13.0", "14.0", "15.0", "16.0", "17.0", "18.0"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(personalText("Custom entitlements", "Entitlements مخصّصة")).font(.subheadline)
                    Text(draft.customEntitlementsName ?? personalText("None. Still limited by the profile.", "ما في. وبتبقى محدودة بالبروفايل.")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if draft.customEntitlements != nil {
                    Button { draft.customEntitlements = nil; draft.customEntitlementsName = nil } label: { Image(systemName: "trash") }
                }
                Button { pickingEntitlements = true } label: { Image(systemName: "square.and.arrow.down") }
            }.buttonStyle(.plain)
        }.padding(16).appsGlass(cornerRadius: 24)
    }
    private func toggle(_ title: String, _ sub: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
        }.tint(.green)
    }
    private var depsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.25)) { showDeps.toggle() } } label: {
                HStack {
                    Label(personalText("Main binary dependencies", "اعتماديات الملف الرئيسي"), systemImage: "link").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(deps.map { "\($0.count)" } ?? "…").foregroundStyle(.secondary)
                    Image(systemName: showDeps ? "chevron.up" : "chevron.down")
                }
            }.buttonStyle(.plain)
            if showDeps { LazyVStack(alignment: .leading, spacing: 8) { ForEach(deps ?? [], id: \.self) { Text($0).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2) } } }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).appsGlass(cornerRadius: 24)
    }
    private func openWorkspace() {
        draftWriter.flush()
        do {
            workspace = ProjectFolderLocation(url: try library.browseDirectory(app))
            draftDestination = library.draftURL(app)
        } catch {
            message = personalText("Could not open this project folder.", "ما قدرنا نفتح مجلد هالمشروع.")
        }
    }
    private func inspect() async {
        let input = library.url(app)
        let result = await PersonalProjectInspection.shared.inspect(input)
        guard !Task.isCancelled else { return }
        extensionCount = result?.extensions ?? 0
        deps = result?.dependencies ?? []
    }

    private var certificateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(personalText("Signing certificate", "شهادة التوقيع"), systemImage: "key.fill").font(.subheadline.weight(.semibold))
            if let selected {
                Text(selected.name).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if !selected.verification.isVerified {
                    Label(selected.verification.warningText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text("Team ID: " + selected.teamID).font(.caption).foregroundStyle(.secondary)
                if let expiry = selected.expiry {
                    Text(personalText("Local expiry date: ", "تاريخ الانتهاء المحلي: ") + expiry.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(personalText("No saved certificate yet.", "ما في شهادة محفوظة.")).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(identities.filter { $0.id != selected?.id }) { identity in
                Toggle(isOn: Binding(get: { (draft.additionalProfileIDs ?? []).contains(identity.id) }, set: { enabled in
                    var ids = draft.additionalProfileIDs ?? []
                    ids.removeAll { $0 == identity.id }
                    if enabled { ids.append(identity.id) }
                    draft.additionalProfileIDs = ids
                })) {
                    Text(personalText("Nested profile", "بروفايل للتطبيقات المضمّنة") + " · " + identity.name).font(.caption)
                }
            }
            if identities.count > 1 {
                Menu {
                    ForEach(identities) { i in Button(i.name + " · " + i.teamID) { try? PersonalIdentityVault.select(i.id); reloadIdentities() } }
                } label: { Label(personalText("Choose certificate", "اختيار الشهادة"), systemImage: "checkmark.seal") }
            }
            if selected == nil {
                Label(personalText("No certificate: export will apply the configuration only and the IPA stays UNSIGNED.", "بدون شهادة: التصدير بيطبّق الإعدادات بس والـ IPA بيضل غير موقّع."), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button { showCertificates = true } label: {
                Label(personalText("Manage certificates", "إدارة الشهادات"), systemImage: "slider.horizontal.3")
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).appsGlass(cornerRadius: 24)
    }

    private func load() async {
        reloadIdentities()
        icon = library.icon(for: app)
        if icon == nil { icon = await library.ensureIcon(for: app) }
        var d = PersonalProjectDraft(name: app.name, bundleID: app.bundleID, version: app.version,
                                     outputFilename: app.name.replacingOccurrences(of: "/", with: "-") + "-signed")
        if let data = try? Data(contentsOf: library.draftURL(app)),
           let saved = try? JSONDecoder().decode(PersonalProjectDraft.self, from: data) { d = saved }
        draftDestination = library.draftURL(app)
        draft = d; loaded = true
    }
    private func reloadIdentities() {
        do {
            identities = try PersonalIdentityVault.savedIdentities()
            selectedID = try PersonalIdentityVault.selectedID()
        } catch { message = error.localizedDescription }
    }
    private func cleanOutput() {
        if let output, output != signing.state?.result?.url { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        output = nil
    }

    private func sign() {
        draftWriter.flush()
        let material = selected?.material
        cleanOutput(); message = nil
        var options = PersonalProjectOptions()
        options.displayName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        options.bundleID = draft.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        options.version = draft.version.trimmingCharacters(in: .whitespacesAndNewlines)
        options.outputFilename = draft.outputFilename
        options.fileSharing = draft.fileSharing
        options.removeURLSchemes = draft.removeURLSchemes
        options.removeEmbeddedProfile = draft.removeEmbeddedProfile
        options.removeWatchApp = draft.removeWatchApp
        options.removeExtensions = draft.removeExtensions ?? false
        options.removeAppClips = draft.removeAppClips ?? false
        options.gameMode = draft.gameMode ?? .keep
        options.fixWhiteIcon = draft.fixWhiteIcon ?? false
        options.newTweaksFirst = draft.newTweaksFirst ?? false
        options.useLoader = draft.directInjection == false
        options.customEntitlements = draft.customEntitlements
        options.exportExtension = draft.exportExtension ?? "ipa"
        options.additionalProfiles = identities.filter { (draft.additionalProfileIDs ?? []).contains($0.id) }.map { $0.material.profile }
        let minimum = draft.minimumOS.trimmingCharacters(in: .whitespacesAndNewlines)
        options.minimumOS = minimum.isEmpty ? nil : minimum
        do {
            if let overlay = draft.bundleOverlay, !overlay.isEmpty {
                options.bundleOverlay = overlay; options.bundleBlobs = bundleDirs.staging; options.bundleOriginal = bundleDirs.original
            }
            let comps = components()
            options.libraries = comps.map(\.url)
            let targets = draft.tweakTargets ?? [:]
            if comps.contains(where: { targets[$0.id] != nil }) {
                guard let main = mainTarget() else { message = personalText("Load targets first.", "حمّل الأهداف أولاً."); return }
                options.injections = comps.map { ["id": $0.id, "library": $0.url.path, "target": targets[$0.id] ?? main] }
                options.injectionOrder = comps.map(\.id)
            }
        } catch { message = error.localizedDescription; return }
        let input = library.url(app)
        let signingOptions = options
        if let material {
            signing.start(projectID: app.id, title: app.name, input: input, material: material,
                          pairingPath: PairingController.pairingFilePath(), options: signingOptions)
            return
        }
        configBusy = true
        Task {
            do {
                output = try await Task.detached(priority: .userInitiated) {
                    try PersonalCertificateSigner.exportConfigurationOnly(ipa: input, options: signingOptions)
                }.value
                draft.appliedTweakIDs = draft.tweakIDs
                message = personalText("Configuration applied. This IPA is NOT signed.", "انطبقت الإعدادات. هاد الـ IPA غير موقّع.")
                sharing = true
            } catch { message = error.localizedDescription }
            configBusy = false
        }
    }

    private func consumeSigningResult() {
        guard let state = signing.state, state.projectID == app.id, !state.running,
              consumedResult != state.id else { return }
        consumedResult = state.id
        guard let result = state.result else {
            let text = state.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            message = (text?.isEmpty == false) ? text : personalText("Signing stopped before it finished. Try again.", "توقف التوقيع قبل ما يكتمل. جرّب من جديد.")
            resultAlert = message; return
        }
        output = result.url
        draft.appliedTweakIDs = draft.tweakIDs
        if result.installed { message = personalText("Signed and installed.", "تم التوقيع والتثبيت.") }
        else {
            message = personalText("Signed locally but install failed: ", "تم التوقيع بس التثبيت فشل: ") + (result.installError ?? "")
                + "\n" + personalText("The signed IPA was kept for sharing.", "الـ IPA الموقّع انحفظ للمشاركة.")
        }
        if result.bundleIdentifierChanged { message = (message ?? "") + "\nتم تغيير المعرّف ليطابق البروفايل" }
        if !result.verification.isVerified { message = (message ?? "") + "\n" + result.verification.warningText }
        sharing = !result.installed
        resultAlert = message
    }
}
