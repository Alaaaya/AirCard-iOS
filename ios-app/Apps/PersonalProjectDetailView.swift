import SwiftUI
import UniformTypeIdentifiers

struct PersonalProjectDetailView: View {
    let app: PersonalLibraryApp
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = PersonalAppsLibrary.shared
    @StateObject private var tweaks = IPATweakLibrary.shared
    @State private var draft = PersonalProjectDraft()
    @State private var loaded = false
    @State private var identities: [PersonalIdentityVault.SavedIdentity] = []
    @State private var selectedID: String?
    @State private var showCertificates = false
    @State private var pickingTweak = false
    @State private var busy = false
    @State private var message: String?
    @State private var output: URL?
    @State private var sharing = false
    @State private var icon: UIImage?

    private var selected: PersonalIdentityVault.SavedIdentity? {
        identities.first { $0.id == selectedID } ?? identities.first
    }
    private func tweak(_ id: UUID) -> IPATweak? { tweaks.items.first { $0.id == id } }

    var body: some View {
        ZStack {
            AuroraBackground()
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
                    certificateCard
                    Text(personalText("Entitlements import is not available yet. Extensions and App Clips are rejected by the signer.",
                                      "استيراد Entitlements مو متاح حالياً. الإضافات وApp Clips بيرفضهم المُوقّع."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let message { Text(message).font(.footnote).textSelection(.enabled) }
                }.padding(20).padding(.bottom, 110)
            }.scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            Button { sign() } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView() } else { Image(systemName: "hammer.fill") }
                    Text(personalText("Sign and export IPA", "توقيع وتصدير IPA")).fontWeight(.semibold)
                }.frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).tint(.green)
            .disabled(busy || selected == nil)
            .padding(.horizontal, 20).padding(.bottom, 8).padding(.top, 8)
            .background(.ultraThinMaterial)
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
        .sheet(isPresented: $sharing, onDismiss: cleanOutput) {
            if let output { PersonalSignedShare(url: output) }
        }
        .task { await load() }
        .onChange(of: draft) { _ in if loaded { saveDraft() } }
        .onDisappear { if !sharing { cleanOutput() } }
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
            }
        }.padding(16).appsGlass(cornerRadius: 24)
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
                Text(".ipa").foregroundStyle(.secondary)
            }.padding(12).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            if ids.isEmpty {
                Text(personalText("No tweaks. Add .dylib, .deb or .framework files.", "ما في إضافات. ضيف ملفات .dylib أو .deb أو .framework."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                HStack(spacing: 10) {
                    Button { draft.tweakIDs.removeAll { $0 == id } } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tweak(id)?.name ?? "").font(.subheadline).lineLimit(1)
                        Text(personalText("Via main executable", "عبر الملف التنفيذي الرئيسي")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { move(id, -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                    Button { move(id, 1) } label: { Image(systemName: "arrow.down") }.disabled(index == ids.count - 1)
                }.buttonStyle(.plain).padding(10).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }.padding(16).appsGlass(cornerRadius: 24)
    }
    private func move(_ id: UUID, _ delta: Int) {
        guard let i = draft.tweakIDs.firstIndex(of: id), draft.tweakIDs.indices.contains(i + delta) else { return }
        draft.tweakIDs.swapAt(i, i + delta)
    }
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(personalText("Project settings", "إعدادات المشروع"), systemImage: "gearshape.fill").font(.subheadline.weight(.semibold))
            toggle(personalText("Enable Files access", "تمكين الوصول إلى الملفات"), personalText("Shows app documents in Files.", "بيظهر ملفات التطبيق بتطبيق الملفات."), $draft.fileSharing)
            toggle(personalText("Remove URL schemes", "إزالة مخططات URL"), personalText("Deletes the app's custom URL schemes.", "بيحذف مخططات URL تبع التطبيق."), $draft.removeURLSchemes)
            toggle(personalText("Remove old embedded profile", "إزالة البروفايل المضمّن القديم"), personalText("Only the old one. Signing still embeds your new profile.", "القديم بس. التوقيع لسا بيضمّن البروفايل الجديد تبعك."), $draft.removeEmbeddedProfile)
            toggle(personalText("Remove Watch app", "إزالة تطبيق الساعة"), personalText("Deletes the Watch folder before signing.", "بيحذف مجلد الساعة قبل التوقيع."), $draft.removeWatchApp)
            VStack(alignment: .leading, spacing: 4) {
                Text(personalText("Minimum iOS version", "أدنى إصدار iOS")).font(.subheadline)
                TextField(personalText("Keep original, or e.g. 15.0", "الأصلي، أو مثلاً 15.0"), text: $draft.minimumOS)
                    .keyboardType(.numbersAndPunctuation).padding(12)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
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
    private var certificateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(personalText("Signing certificate", "شهادة التوقيع"), systemImage: "key.fill").font(.subheadline.weight(.semibold))
            if let selected {
                Text(selected.name).font(.headline).foregroundStyle(.green)
                Text("Team ID: " + selected.teamID).font(.caption).foregroundStyle(.secondary)
                if let expiry = selected.expiry {
                    Text(personalText("Local expiry date: ", "تاريخ الانتهاء المحلي: ") + expiry.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(personalText("No saved certificate yet.", "ما في شهادة محفوظة.")).font(.footnote).foregroundStyle(.secondary)
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
        draft = d; loaded = true
    }
    private func saveDraft() {
        try? JSONEncoder().encode(draft).write(to: library.draftURL(app), options: [.atomic, .completeFileProtection])
    }
    private func reloadIdentities() {
        do {
            identities = try PersonalIdentityVault.savedIdentities()
            selectedID = try PersonalIdentityVault.selectedID()
        } catch { message = error.localizedDescription }
    }
    private func cleanOutput() {
        if let output { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        output = nil
    }

    private func sign() {
        guard let material = selected?.material else { return }
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
        let minimum = draft.minimumOS.trimmingCharacters(in: .whitespacesAndNewlines)
        options.minimumOS = minimum.isEmpty ? nil : minimum
        do {
            options.libraries = try draft.tweakIDs.flatMap { try tweaks.urls(for: [$0]) }
        } catch { message = error.localizedDescription; return }
        let input = library.url(app)
        let signingOptions = options
        busy = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try PersonalCertificateSigner.sign(ipa: input, material: material, options: signingOptions)
                }.value
                output = result.url
                message = personalText("Signed locally. Exporting does not install the app.", "تم التوقيع على جهازك. التصدير ما بيثبّت التطبيق.")
                if result.bundleIdentifierChanged {
                    message = (message ?? "") + "\n" + "تم تغيير المعرّف ليطابق البروفايل"
                }
                sharing = true
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}
