import SwiftUI
import WebKit

/// Minimal in-app browser. Entry contract for the integrator:
///   .fullScreenCover(isPresented: $show) { MirsaBrowserView(initialURL: nil) { show = false } }
/// IPA responses are cancelled in the web view and routed to MirsaBrowserRouter (pinned transport).
@MainActor
final class MirsaBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    @Published var progress: Double = 0
    @Published var address = ""
    @Published var notice: String?
    let router: MirsaBrowserRouter
    let webView: WKWebView
    private var observers: [NSKeyValueObservation] = []

    init(router: MirsaBrowserRouter? = nil) {
        self.router = router ?? MirsaBrowserRouter()
        let config = WKWebViewConfiguration()
        // Isolated, non-persistent store: nothing from this browser is shared with other contexts.
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observers = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.canGoForward = w.canGoForward } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.loading = w.isLoading } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.progress = w.estimatedProgress } },
            webView.observe(\.url, options: [.new]) { [weak self] w, _ in Task { @MainActor in if let u = w.url, u.scheme != "about" { self?.address = u.absoluteString } } }
        ]
    }

    func go(_ text: String) {
        guard let url = MirsaBrowserPolicy.address(from: text) else { notice = tr("Enter a web address.", "اكتب عنوان موقع."); return }
        notice = nil
        webView.load(URLRequest(url: url))
    }

    // MARK: navigation policy
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        switch MirsaBrowserPolicy.decide(navigation: url) {
        case .allow: decisionHandler(.allow)
        case .refuse(let why): notice = why; decisionHandler(.cancel)
        case .download(let u): router.route(u); decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse,
              let url = http.url else { decisionHandler(.allow); return }
        let verdict = MirsaBrowserPolicy.decide(response: url, mimeType: http.mimeType,
            contentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"), canShow: navigationResponse.canShowMIMEType)
        switch verdict {
        case .allow: decisionHandler(.allow)
        case .refuse(let why): notice = why; decisionHandler(.cancel)
        case .download(let u):
            // Always cancel: never hand the response to WKDownload (it would carry web cookies).
            let size = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            router.route(u, expectedBytes: size)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           MirsaBrowserPolicy.decide(navigation: url) == .allow { webView.load(navigationAction.request) }
        return nil
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct MirsaBrowserView: View {
    @StateObject private var model = MirsaBrowserModel()
    @State private var field = ""
    @FocusState private var focused: Bool
    let initialURL: URL?
    let onClose: () -> Void

    init(initialURL: URL? = nil, onClose: @escaping () -> Void) {
        self.initialURL = initialURL
        self.onClose = onClose
    }

    var body: some View {
        BrowserBody(model: model, field: $field, focused: $focused, initialURL: initialURL, onClose: onClose)
    }
}

private struct BrowserBody: View {
    @ObservedObject var model: MirsaBrowserModel
    @ObservedObject var router: MirsaBrowserRouter
    @Binding var field: String
    var focused: FocusState<Bool>.Binding
    let initialURL: URL?
    let onClose: () -> Void

    init(model: MirsaBrowserModel, field: Binding<String>, focused: FocusState<Bool>.Binding, initialURL: URL?, onClose: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model); _router = ObservedObject(wrappedValue: model.router); _field = field; self.focused = focused
        self.initialURL = initialURL; self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack(alignment: .top) {
                BrowserWebView(webView: model.webView)
                if model.loading { ProgressView(value: model.progress).progressViewStyle(.linear).tint(.white) }
            }
            if !router.items.isEmpty { downloads }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.layoutDirection, .leftToRight)
        .onAppear { if let u = initialURL { model.webView.load(URLRequest(url: u)) } }
        .onChange(of: model.address) { new in if !focused.wrappedValue { field = new } }
    }

    private func icon(_ name: String, label: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.10), in: Circle())
                .foregroundColor(.white.opacity(enabled ? 1 : 0.3))
        }.disabled(!enabled).accessibilityLabel(label)
    }

    private var bar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                icon("xmark", label: tr("Close", "إغلاق"), onClose)
                icon("chevron.left", label: tr("Back", "رجوع"), enabled: model.canGoBack) { model.webView.goBack() }
                icon("chevron.right", label: tr("Forward", "قدام"), enabled: model.canGoForward) { model.webView.goForward() }
                TextField(tr("Search or enter address", "اكتب عنوان"), text: $field)
                    .focused(focused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .submitLabel(.go).onSubmit { focused.wrappedValue = false; model.go(field) }
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(.white)
                icon(model.loading ? "xmark.circle" : "arrow.clockwise", label: tr("Reload", "تحديث")) {
                    if model.loading { model.webView.stopLoading() } else { model.webView.reload() }
                }
            }
            if let n = model.notice {
                Text(n).font(.footnote).foregroundColor(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { model.notice = nil }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var downloads: some View {
        VStack(spacing: 6) {
            ForEach(router.items.prefix(3)) { it in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(it.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        switch it.state {
                        case .downloading(let p):
                            ProgressView(value: p).tint(.white)
                        case .validating: Text(tr("Checking IPA…", "عم يفحص IPA…")).font(.caption).opacity(0.7)
                        case .added: Text(tr("Added to Downloads", "انضاف للتنزيلات")).font(.caption).opacity(0.7)
                        case .failed(let m): Text(m).font(.caption).foregroundColor(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                    switch it.state {
                    case .downloading: icon("xmark", label: tr("Cancel", "إلغاء")) { router.cancel(it.id) }
                    case .added(let bid, let ver):
                        icon("arrow.down.app", label: tr("Install", "تثبيت")) {
                            let item = DownloadsLibrary.shared.items.first { $0.bundleID == bid && $0.version == ver }
                            if let item { NotificationCenter.default.post(name: .mirsaIncomingIPA, object: DownloadsLibrary.ipaURL(item)) }
                            router.dismiss(it.id)
                        }
                    case .failed: icon("xmark", label: tr("Dismiss", "إخفاء")) { router.dismiss(it.id) }
                    case .validating: EmptyView()
                    }
                }
                .padding(10).foregroundColor(.white)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}


extension Notification.Name {
    /// Posted with an IPA file URL; ContentView routes it through the single confirmation sheet.
    static let mirsaIncomingIPA = Notification.Name("mirsa.incomingIPA")
}
