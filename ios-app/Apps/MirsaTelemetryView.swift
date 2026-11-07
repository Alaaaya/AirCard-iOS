import SwiftUI
import UniformTypeIdentifiers

/// Per-app launches + crash viewer. Own file; the parent adds one line in ProjectView:
///   MirsaTelemetryView(bundleID: project.bundleID)
struct MirsaTelemetryView: View {
    let bundleID: String
    var store: MirsaTelemetryStore = .shared
    @State private var launches: [MirsaLaunchRecord] = []
    @State private var crashes: [MirsaCrashReport] = []
    @State private var importing = false
    @State private var error: String?
    @State private var shareRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(tr("Launches & crashes", "التشغيل والانهيارات")).font(.headline)
                Spacer()
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down").frame(width: 40, height: 40) }
                    .appsGlass(cornerRadius: 12, interactive: true)
                    .accessibilityLabel(tr("Import crash log", "استيراد سجل انهيار"))
            }
            Text(tr("Only launches Mirsa itself observed are listed. Launches from the home screen are unknown.",
                    "فقط التشغيلات اللي لاحظها Mirsa. التشغيل من الشاشة الرئيسية غير معروف."))
                .font(.footnote).foregroundStyle(.secondary)
            if let e = error { Text(e).font(.footnote).foregroundStyle(.red) }
            if launches.isEmpty && crashes.isEmpty {
                Text(tr("Nothing recorded yet", "ما في تسجيلات بعد")).foregroundStyle(.secondary)
            }
            ForEach(launches.prefix(5)) { l in
                HStack {
                    Image(systemName: "play.circle")
                    Text(l.date, style: .relative); Spacer()
                    Text(l.source == .loader ? "loader" : "container").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(crashes) { c in
                NavigationLink { MirsaCrashDetailView(report: c) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.readableReason).font(.subheadline).lineLimit(2)
                        Text(c.date.map { $0.formatted() } ?? tr("unknown time", "وقت غير معروف")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16).appsGlass(cornerRadius: 20)
        .onAppear(perform: reload)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data, .plainText], allowsMultipleSelection: false) { res in
            guard case .success(let urls) = res, let u = urls.first else { return }
            let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
            do {
                let d = try Data(contentsOf: u, options: .mappedIfSafe)
                let r = try store.importCrash(d)
                if r.bundleID == nil { store.associate(crashID: r.id, bundleID: bundleID) }   // owner imported it from this app's page
                error = nil
            } catch { self.error = tr("Could not read this crash log", "تعذر قراءة سجل الانهيار") }
            reload()
        }
    }
    private func reload() { launches = store.launches(for: bundleID); crashes = store.crashes(for: bundleID) }
}

struct MirsaCrashDetailView: View {
    let report: MirsaCrashReport
    @State private var showRaw = false
    var body: some View {
        let text = MirsaRedactor.shareText(report, redacted: !showRaw)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(report.readableReason).font(.headline)
                if report.frames.allSatisfy({ !$0.symbolicated }) {
                    Text(tr("Frames are not symbolicated.", "الإطارات غير مفككة الرموز.")).font(.footnote).foregroundStyle(.secondary)
                }
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Toggle(tr("Show unredacted", "إظهار بدون إخفاء"), isOn: $showRaw)
                HStack(spacing: 12) {
                    Button { UIPasteboard.general.string = text } label: { Label(tr("Copy", "نسخ"), systemImage: "doc.on.doc") }
                    ShareLink(item: text) { Label(tr("Share", "مشاركة"), systemImage: "square.and.arrow.up") }
                }
            }.padding(16)
        }
        .mirsaScreen()
        .navigationBarTitleDisplayMode(.inline)
    }
}
