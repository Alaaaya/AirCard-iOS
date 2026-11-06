import SwiftUI
import UIKit
import AppIntents

struct NoProfileShortcutGuide: View {
    let app: ManagedApp
    @State private var sharing = false
    private var launchURL: URL {
        var c = URLComponents()
        c.scheme = "mirsa"; c.host = "launch"
        c.queryItems = [URLQueryItem(name: "app", value: app.id)]
        return c.url!
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 14) {
                        if let icon = UIImage(contentsOfFile: AppsStore.iconURL(app.id).path) {
                            Image(uiImage: icon).resizable().scaledToFit()
                                .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(app.name).font(.title2.bold())
                            Label(tr("No profile needed", "بدون بروفايل"), systemImage: "checkmark.shield")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    step("1", icon: "square.stack.3d.up", text: tr(
                        "Open Mirsa’s shortcuts below.",
                        "افتح اختصارات Mirsa من الزر تحت."))
                    step("2", icon: "app.badge.checkmark", text: tr(
                        "Press and hold Open Saved App, then choose New Shortcut. Check that the app is \(app.name).",
                        "اضغط مطوّل على Open Saved App واختار اختصار جديد. تأكّد إن التطبيق \(app.name)."))
                    step("3", icon: "plus.square", text: tr(
                        "From the shortcut’s menu, choose Add to Home Screen, then Add.",
                        "من قائمة الاختصار اختار إضافة للشاشة الرئيسية، وبعدين إضافة."))
                    ShortcutsLink {
                        // Only influences the new shortcut's initial entity suggestion.
                        // Saved shortcuts retain their own stable app ID.
                        UserDefaults.standard.set(app.id, forKey: MirsaShortcutAppQuery.preferredAppKey)
                        AirCardAppShortcuts.updateAppShortcutParameters()
                    }
                    .shortcutsLinkStyle(.dark)
                    .frame(maxWidth: .infinity)
                    Text(tr("iOS still asks you to confirm adding the icon. Mirsa opens briefly before your app.",
                            "لازم تأكّد إضافة الأيقونة من iOS. Mirsa بيفتح لحظة قبل تطبيقك."))
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button { sharing = true } label: {
                            Label(tr("Share icon", "شارك الأيقونة"), systemImage: "photo")
                        }
                        Spacer()
                        ShareLink(item: launchURL) {
                            Label(tr("Launch link", "رابط الفتح"), systemImage: "link")
                        }
                    }.font(.subheadline)
                }
                .padding(24)
            }
            .navigationTitle(tr("Home Screen shortcut", "اختصار الشاشة الرئيسية"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $sharing) {
                ShortcutAssetsSheet(name: app.name, icon: UIImage(contentsOfFile: AppsStore.iconURL(app.id).path))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .preferredColorScheme(.dark)
    }

    private func step(_ number: String, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint)
                .frame(width: 28).accessibilityLabel(number)
            Text(text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ShortcutAssetsSheet: UIViewControllerRepresentable {
    let name: String
    let icon: UIImage?
    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = [name]
        if let icon { items.append(icon) }
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
