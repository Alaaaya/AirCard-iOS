import SwiftUI
import UIKit

/// Parent owns the incoming snapshot and the only onOpenURL router.
/// Callbacks run only after explicit taps; presenting/dismissing never installs.
struct IncomingIPAConfirmationSheet: View {
    let url: URL
    let filename: String
    let onCancel: () -> Void
    let onImportProject: (URL) -> Void
    var onAppleID: ((URL) -> Void)? = nil
    var onSaveLibrary: ((URL) -> Void)? = nil
    let onSignInstall: (URL, PersonalIdentityVault.SavedIdentity) -> Void
    /// Supply ONLY when the existing direct-install path validated this exact
    /// snapshot/device. Signature/profile presence alone is NOT eligibility.
    var onDirectInstall: ((URL) -> Void)? = nil
    @ObservedObject private var store = AppsStore.shared
    @State private var login = false
    @State private var preview: IncomingIPAPreview?
    @State private var error: String?
    @State private var loading = true
    @State private var submitted = false
    @State private var certificates = false
    @State private var selected: PersonalIdentityVault.SavedIdentity?
    @State private var savedProfile: IncomingProfile?
    @State private var originalExpanded = false
    @State private var profileExpanded = false
    @State private var savedExpanded = false
    @State private var copiedKey: String?
    private let gold = Color(red: 0.91, green: 0.76, blue: 0.48)
    private let violet = Color(red: 0.65, green: 0.58, blue: 1)

    var body: some View {
        ZStack {
            AuroraBackground()
            LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.68)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        Button { guard !submitted else { return }; onCancel() } { Image(systemName: "xmark").font(.headline).padding(12).appsGlass(cornerRadius: 14) }
                            .accessibilityLabel(tr("Cancel", "إلغاء"))
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("MIRSA").font(.caption.weight(.bold)).tracking(5).foregroundStyle(gold)
                            Text(tr("Confirm IPA", "تأكيد ملف IPA")).font(.title2.weight(.bold))
                        }
                    }.foregroundStyle(.white)
                    if loading {
                        VStack(spacing: 12) {
                            ProgressView().tint(gold)
                            Text(tr("Reading app details…", "عم نقرأ معلومات التطبيق…")).font(.subheadline)
                        }.frame(maxWidth: .infinity).padding(40).appsGlass(cornerRadius: 24)
                    }
                    if let preview {
                        header(preview)
                        card(tr("File information", "معلومات الملف"), icon: "doc.zipper") {
                            detail(tr("Bundle ID", "معرّف التطبيق"), preview.bundleID)
                            detail(tr("Version", "الإصدار"), preview.version)
                            detail(tr("Size", "الحجم"), ByteCountFormatter.string(fromByteCount: preview.size, countStyle: .file))
                            detail(tr("File name", "اسم الملف"), filename)
                        }
                        card(tr("Original executable entitlements", "صلاحيات التطبيق الأصلية"), icon: "lock.shield") {
                            Text(tr("These are declared keys, not proof of effective permissions, sandbox escape or certificate trust.",
                                    "هاي المفاتيح المعلنة بالملف، مو إثبات للصلاحيات الفعلية أو الخروج من العزل أو ثقة الشهادة."))
                                .font(.caption).foregroundStyle(.secondary)
                            if preview.signature.entitlementsUnavailable == true {
                                Text(tr("Entitlements unavailable or unsupported. No permissions inferred.", "ما قدرنا نقرأ الصلاحيات بهالصيغة. ما منفترض صلاحيات.")).font(.footnote)
                            } else if preview.signature.entitlements.isEmpty {
                                Text(tr("No entitlement keys found.", "ما لقينا مفاتيح صلاحيات.")).font(.footnote)
                            } else {
                                entitlementList(preview.signature.entitlements, expanded: $originalExpanded)
                            }
                            Text(tr("Sandbox, app groups and containers are shown only through their exact declared keys below; missing keys are not a universal capability verdict.",
                                    "العزل ومجموعات التطبيقات والحاويات بتنعرض بمفاتيحها الأصلية فقط؛ غياب مفتاح ما بيحكم على كل قدرات التطبيق."))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let profile = preview.signature.embeddedProfile {
                            profileCard(profile, title: tr("Original embedded profile", "البروفايل الأصلي داخل الملف"), expanded: $profileExpanded)
                        } else {
                            card(tr("Original embedded profile", "البروفايل الأصلي داخل الملف"), icon: "person.text.rectangle") {
                                Text(preview.signature.profileUnavailable == true
                                     ? tr("Embedded profile could not be read.", "ما قدرنا نقرأ البروفايل الموجود.")
                                     : tr("No embedded provisioning profile.", "ما في بروفايل توقيع داخل الملف.")).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        card(tr("Selected signing certificate", "الشهادة المحددة للتوقيع"), icon: "signature") {
                            if let selected {
                                detail(tr("Certificate CN", "اسم الشهادة"), selected.name)
                                if let savedProfile {
                                    detail(tr("Saved profile", "البروفايل المحفوظ"), savedProfile.name)
                                    detail(tr("Profile ID (short)", "معرّف البروفايل المختصر"), savedProfile.shortID)
                                    entitlementList(savedProfile.entitlements, expanded: $savedExpanded)
                                } else {
                                    Text(tr("Saved profile details unavailable.", "تفاصيل البروفايل المحفوظ مو متاحة.")).font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Text(tr("No saved certificate selected.", "ما في شهادة محفوظة محددة.")).font(.footnote)
                            }
                            Button { certificates = true } label: {
                                Label(tr("Choose / import certificate", "اختيار أو استيراد شهادة"), systemImage: "key")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(gold)
                            }
                            Text(tr("This saved identity is separate from the original embedded profile. iOS validates eligibility at installation.",
                                    "هاي الشهادة المحفوظة منفصلة عن البروفايل الأصلي. iOS بيفحص السماح بالتثبيت.")).font(.caption2).foregroundStyle(.secondary)
                        }
                        Label(tr("To add dylibs or change the bundle ID, icon or file sharing, import this IPA into a project first.",
                                 "لإضافة dylibs أو تغيير المعرّف أو الأيقونة أو مشاركة الملفات، استورد الـIPA لمشروع أولاً."),
                              systemImage: "sparkles").font(.footnote).foregroundStyle(gold.opacity(0.9))
                            .padding(16).appsGlass(cornerRadius: 18, tint: gold)
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
                }.padding(20).padding(.bottom, 12)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .leftToRight)
        .interactiveDismissDisabled(submitted)
        .sheet(isPresented: $login, onDismiss: {
            if store.account != nil, let onAppleID { submit(onAppleID) }
        }) { LoginSheet(store: store) }
        .task {
            guard preview == nil else { return }
            do {
                preview = try await IncomingIPAPreviewCache.shared.preview(url)
            } catch { self.error = error.localizedDescription }
            loading = false
            await reloadCertificate()
        }
        .sheet(isPresented: $certificates, onDismiss: { Task { await reloadCertificate() } }) {
            PersonalCertificateManagerView()
        }
    }

    private func header(_ p: IncomingIPAPreview) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let icon = p.icon { Image(uiImage: icon).resizable().scaledToFit() }
                else { Image(systemName: "app.dashed").resizable().scaledToFit().padding(16).foregroundStyle(violet) }
            }.frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 19))
                .overlay(RoundedRectangle(cornerRadius: 19).stroke(gold.opacity(0.5), lineWidth: 1))
            VStack(alignment: .leading, spacing: 8) {
                Text(p.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                Text(p.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 8) {
                    chip(p.version, color: violet)
                    chip(p.signature.signaturePresent == true ? tr("Signature present", "يوجد توقيع")
                         : p.signature.signaturePresent == false ? tr("Unsigned", "غير موقّع")
                         : tr("Signature unknown", "التوقيع غير معروف"), color: gold)
                }
            }
            Spacer(minLength: 0)
        }.padding(18).appsGlass(cornerRadius: 26, tint: violet)
    }
    private func chip(_ title: String, color: Color) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }
    private func card<C: View>(_ title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: icon).font(.subheadline.weight(.bold)).foregroundStyle(gold)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).appsGlass(cornerRadius: 23)
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value.isEmpty ? tr("Not supplied", "غير مذكور") : value).font(.subheadline).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func entitlementList(_ rows: [IncomingEntitlement], expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(expanded.wrappedValue ? rows : Array(rows.prefix(5)))) { row in
                Button {
                    UIPasteboard.general.string = row.key + "\n" + row.value
                    copiedKey = row.key
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.key).font(.caption.monospaced()).foregroundStyle(violet).multilineTextAlignment(.leading)
                            Text(row.value).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.leading).lineLimit(expanded.wrappedValue ? nil : 4)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: copiedKey == row.key ? "checkmark" : "doc.on.doc").font(.caption).foregroundStyle(gold)
                    }.padding(10).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain).accessibilityLabel(tr("Copy ", "نسخ ") + row.key)
            }
            if rows.count > 5 {
                Button { expanded.wrappedValue.toggle() } label: {
                    Text(expanded.wrappedValue ? tr("Show less", "عرض أقل") : MirsaTr.p("showAllKeys", rows.count))
                        .font(.caption.weight(.semibold)).foregroundStyle(gold)
                }
            }
        }
    }
    private func profileCard(_ p: IncomingProfile, title: String, expanded: Binding<Bool>) -> some View {
        card(title, icon: "person.text.rectangle") {
            detail(tr("Profile certificate CNs", "أسماء شهادات البروفايل"), p.certificateNames.joined(separator: "\n"))
            detail(tr("Profile name", "اسم البروفايل"), p.name)
            detail(tr("Profile ID (short)", "معرّف البروفايل المختصر"), p.shortID)
            Text(tr("Presence only. Trust, revocation and device authorization are not verified here.",
                    "وجوده فقط. الثقة والإلغاء والسماح لجهازك مو متحقق منهم هون.")).font(.caption2).foregroundStyle(.secondary)
            entitlementList(p.entitlements, expanded: expanded)
        }
    }
    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(tr("Cancel", "إلغاء")) { guard !submitted else { return }; onCancel() }.frame(maxWidth: .infinity).padding(.vertical, 11).appsGlass(cornerRadius: 13)
                Button { submit(onImportProject) } label: {
                    Text(tr("Import to project", "استيراد لمشروع")).frame(maxWidth: .infinity).padding(.vertical, 11)
                }.appsGlass(cornerRadius: 13, tint: violet).disabled(preview == nil || submitted)
            }.font(.subheadline.weight(.semibold))
            if let onSaveLibrary {
                Button { submit(onSaveLibrary) } label: {
                    Label(tr("Save to my library", "حفظ بمكتبتي"), systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                }.font(.subheadline.weight(.semibold)).appsGlass(cornerRadius: 13, tint: violet)
                    .accessibilityIdentifier("mirsa.incoming.library")
                    .disabled(preview == nil || submitted)
            }
            if let onAppleID {
                Button {
                    if store.account == nil && !store.hasSavedLogin { login = true }
                    else { submit(onAppleID) }
                } label: {
                    Label(tr("Install with Apple ID", "تثبيت بـ Apple ID"), systemImage: "apple.logo")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                }.appsGlass(cornerRadius: 15, tint: violet)
                    .accessibilityIdentifier("mirsa.incoming.appleID")
                    .disabled(preview == nil || submitted)
            }
            Button {
                if let selected {
                    guard preview != nil, !submitted else { return }
                    submitted = true
                    onSignInstall(url, selected)
                } else { certificates = true }
            } label: {
                Label(tr("Sign & install with certificate", "توقيع وتثبيت بالشهادة"), systemImage: "signature").font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .foregroundStyle(Color(red: 0.12, green: 0.09, blue: 0.18))
                    .background(LinearGradient(colors: [gold, Color(red: 0.98, green: 0.88, blue: 0.67)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 15))
            }.accessibilityIdentifier("mirsa.incoming.certificate").disabled(preview == nil || submitted)
            if let onDirectInstall {
                Button { submit(onDirectInstall) } label: {
                    Label(tr("Direct install", "تثبيت مباشر"), systemImage: "square.and.arrow.down").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }.appsGlass(cornerRadius: 13).disabled(preview == nil || submitted)
            }
        }.buttonStyle(.plain).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
            .background(.ultraThinMaterial)
    }
    private func submit(_ callback: (URL) -> Void) {
        guard preview != nil, !submitted else { return }
        submitted = true
        callback(url)
    }
    @MainActor private func reloadCertificate() async {
        do {
            let id = try PersonalIdentityVault.selectedID()
            selected = try PersonalIdentityVault.savedIdentities().first { $0.id == id }
            savedProfile = nil
            if let bytes = selected?.material.profile {
                savedProfile = try? await Task.detached(priority: .utility) { try IncomingIPAInspection.savedProfile(bytes) }.value
            }
        } catch { selected = nil; savedProfile = nil }
    }
}
