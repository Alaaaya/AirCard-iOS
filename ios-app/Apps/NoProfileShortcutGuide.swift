import SwiftUI
import UIKit

struct NoProfileShortcutGuide: View {
    let app: ManagedApp
    @State private var sharing = false
    private var launchURL: URL {
        var c = URLComponents()
        c.scheme = "mirsa"; c.host = "launch"
        c.queryItems = [URLQueryItem(name: "app", value: app.id)]
        return c.url!
    }
    private var guide: String {
        MirsaTr.f("shortcut", app.name, app.id, launchURL.absoluteString)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(app.name).font(.title2.bold())
                Text(guide).textSelection(.enabled)
                Button(tr("Share guide and icon", "شارك التعليمات والأيقونة")) { sharing = true }
                    .buttonStyle(.borderedProminent)
                ShareLink(item: launchURL) { Label(tr("Share launch link", "شارك رابط الفتح"), systemImage: "link") }
            }
            .padding()
            .navigationTitle(tr("No-profile shortcut", "اختصار بدون بروفايل"))
            .sheet(isPresented: $sharing) {
                ShortcutAssetsSheet(text: guide, icon: UIImage(contentsOfFile: AppsStore.iconURL(app.id).path))
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct ShortcutAssetsSheet: UIViewControllerRepresentable {
    let text: String
    let icon: UIImage?
    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = [text]
        if let icon { items.append(icon) }
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
