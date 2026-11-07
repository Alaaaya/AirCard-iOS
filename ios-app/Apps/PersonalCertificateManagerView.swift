import SwiftUI

struct PersonalCertificateManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var identities: [PersonalIdentityVault.SavedIdentity] = []
    @State private var selectedID: String?
    @State private var adding = false
    @State private var removing: PersonalIdentityVault.SavedIdentity?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(personalText("Signing certificates", "شهادات التوقيع")).font(.title2.bold())
                        Text(personalText("The selected certificate is used for signing. Dates come from the files on this device; they do not prove the certificate is valid or unrevoked.",
                                          "الشهادة المحددة هي اللي بتوقّع. التواريخ من الملفات على جهازك، وما بتثبت إنو الشهادة صالحة أو مو ملغاة."))
                            .font(.footnote).foregroundStyle(.secondary)
                        if identities.isEmpty {
                            Text(personalText("No saved certificates yet.", "ما في شهادات محفوظة.")).font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(identities) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Button { choose(item) } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: item.id == selectedID ? "checkmark.circle.fill" : "circle")
                                            .font(.title3).foregroundStyle(item.id == selectedID ? Color.green : Color.secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.name).font(.headline).lineLimit(2)
                                            Text("Team ID: " + item.teamID).font(.caption).foregroundStyle(.secondary)
                                            Text(item.bundleID).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                            if !item.profileType.isEmpty { Text(item.profileType).font(.caption2).foregroundStyle(.secondary) }
                                            if let e = item.expiry {
                                                Text(personalText("Local expiry date: ", "تاريخ الانتهاء المحلي: ") + e.formatted(date: .abbreviated, time: .omitted))
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }.buttonStyle(.plain)
                                NavigationLink { PersonalCertificateDetailsView(identity: item) } label: { Image(systemName: "info.circle") }
                                Button(role: .destructive) { removing = item } label: { Image(systemName: "trash") }
                            }.padding(16).appsGlass(cornerRadius: 22)
                        }
                        Button { adding = true } label: {
                            Label(personalText("Add certificate", "إضافة شهادة"), systemImage: "plus.circle.fill").fontWeight(.semibold)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }.buttonStyle(.borderedProminent).tint(.green)
                        if let message { Text(message).font(.footnote) }
                    }.padding(20)
                }
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(personalText("Back", "رجوع")) { dismiss() } } }
        }
        .preferredColorScheme(.dark).environment(\.layoutDirection, .leftToRight)
        .sheet(isPresented: $adding, onDismiss: reload) {
            NavigationStack {
                ScrollView { PersonalCertificateView(onSaved: reload).padding(20) }
                    .background(AuroraBackground())
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button(personalText("Back", "رجوع")) { adding = false } } }
            }.preferredColorScheme(.dark).environment(\.layoutDirection, .leftToRight)
        }
        .confirmationDialog(personalText("Delete this certificate?", "حذف هالشهادة؟"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { item in
            Button(personalText("Delete", "حذف"), role: .destructive) {
                do { try PersonalIdentityVault.remove(item.id) } catch { message = error.localizedDescription }
                removing = nil; reload()
            }
        } message: { item in
            Text(item.name + "\n" + personalText("Its P12 and profile are removed from this device. Apps already signed are not affected.", "الـP12 والبروفايل بينحذفوا من الجهاز. التطبيقات الموقّعة قبل ما بتتأثر."))
        }
        .task { reload() }
    }
    private func reload() {
        do {
            identities = try PersonalIdentityVault.savedIdentities()
            selectedID = try PersonalIdentityVault.selectedID()
        } catch { message = error.localizedDescription }
    }
    private func choose(_ item: PersonalIdentityVault.SavedIdentity) {
        do { try PersonalIdentityVault.select(item.id); selectedID = item.id }
        catch { message = error.localizedDescription }
    }
}
