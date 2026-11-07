import SwiftUI

@MainActor
final class ScreenshotGalleryModel: ObservableObject {
    enum Origin { case source, appStore }
    @Published var urls: [URL]
    @Published var origin: Origin = .source
    @Published var resolved = false
    let bundleID: String
    private let loader: ScreenshotLoader
    init(sourceURLs: [URL], bundleID: String, loader: ScreenshotLoader = .shared) {
        urls = sourceURLs; self.bundleID = bundleID; self.loader = loader
    }
    func resolve() async {
        guard urls.isEmpty, !resolved else { resolved = true; return }
        let found = await loader.appStoreFallback(bundleID: bundleID)
        if !Task.isCancelled { urls = found; origin = .appStore; resolved = true }
    }
    /// Called when every source image failed; retries once via the App Store.
    func sourceFailed() async {
        guard origin == .source, !urls.isEmpty else { return }
        let found = await loader.appStoreFallback(bundleID: bundleID)
        if !Task.isCancelled, !found.isEmpty { urls = found; origin = .appStore }
    }
}

struct ScreenshotImage: View {
    let url: URL
    var onFailure: (() -> Void)? = nil
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "photo.badge.exclamationmark").font(.title2).foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .task(id: url) {
            failed = false; image = nil
            do { image = try await ScreenshotLoader.shared.image(url) }
            catch is CancellationError { }
            catch { if !Task.isCancelled { failed = true; onFailure?() } }
        }
    }
}

struct AppScreenshotGallery: View {
    @StateObject private var model: ScreenshotGalleryModel
    @State private var failures = Set<URL>()
    @State private var fullscreen: Int?
    init(app: RepoApp) { _model = StateObject(wrappedValue: ScreenshotGalleryModel(sourceURLs: app.screenshots, bundleID: app.bundleID)) }

    var body: some View {
        Group {
            if model.urls.isEmpty {
                if model.resolved {
                    EmptyView()
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)).frame(height: 120)
                        .overlay(ProgressView())
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Preview", "معاينة")).font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(Array(model.urls.enumerated()), id: \.element) { i, u in
                                Button { fullscreen = i } label: {
                                    ScreenshotImage(url: u) {
                                        failures.insert(u)
                                        if failures.count == model.urls.count { Task { failures = []; await model.sourceFailed() } }
                                    }
                                    .frame(width: 130, height: 260)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(MirsaTr.f("screenshot", i + 1, model.urls.count))
                                .accessibilityAddTraits(.isButton)
                            }
                        }
                    }
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .task { await model.resolve() }
        .fullScreenCover(item: Binding(get: { fullscreen.map(FullIndex.init) }, set: { fullscreen = $0?.value })) { idx in
            FullscreenScreenshots(urls: model.urls, start: idx.value)
        }
    }
    private struct FullIndex: Identifiable { let value: Int; var id: Int { value } }
}

struct FullscreenScreenshots: View {
    let urls: [URL]
    @State var page: Int
    @Environment(\.dismiss) private var dismiss
    init(urls: [URL], start: Int) { self.urls = urls; _page = State(initialValue: start) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(urls.enumerated()), id: \.element) { i, u in
                    ScreenshotImage(url: u).background(Color.black).tag(i)
                        .accessibilityLabel(MirsaTr.f("screenshot", i + 1, urls.count))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
                        .background(.white.opacity(0.18), in: Circle())
                }
                .accessibilityLabel(tr("Close", "إغلاق"))
                Spacer()
                Text("\(page + 1) / \(urls.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
            }
            .padding(16)
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityAction(.escape) { dismiss() }
    }
}
