import Foundation
import SwiftUI

/// Routes IPA candidates found by the in-app browser into the existing pipeline:
/// pinned Discovery transport -> IPAValidator -> DownloadsLibrary (install stays the
/// usual Downloads step). No cookies or credentials from the web view are forwarded;
/// a link that needs a login fails with an honest message. There is no URLSession
/// or WKDownload fallback.
@MainActor
final class MirsaBrowserRouter: ObservableObject {
    enum State: Equatable { case downloading(Double), validating, added(bundleID: String, version: String), failed(String) }
    struct Item: Identifiable, Equatable {
        let id: String            // dedupe key
        var title: String
        var state: State
    }

    @Published private(set) var items: [Item] = []
    private var inflight: [String: DiscoveryDownloader] = [:]
    private var finishedAt: [String: Date] = [:]
    static let recentWindow: TimeInterval = 30

    /// Returns false when this URL is already downloading, or was just handled.
    @discardableResult
    func route(_ url: URL, expectedBytes: Int64? = nil, now: Date = Date()) -> Bool {
        let key = MirsaBrowserPolicy.dedupeKey(url)
        if inflight[key] != nil { return false }
        if let t = finishedAt[key], now.timeIntervalSince(t) < Self.recentWindow { return false }
        let name = url.lastPathComponent.isEmpty ? (url.host ?? "IPA") : url.lastPathComponent
        let downloader = DiscoveryDownloader()
        inflight[key] = downloader
        setItem(Item(id: key, title: name, state: .downloading(0)))
        let op = MirsaOperationProgress.shared.begin(phase: .downloading, cancel: { [weak downloader] in downloader?.cancel() })
        Task { await run(url, key: key, expectedBytes: expectedBytes, downloader: downloader, op: op) }
        return true
    }

    func cancel(_ id: String) { inflight[id]?.cancel() }
    func dismiss(_ id: String) { if inflight[id] == nil { items.removeAll { $0.id == id } } }

    private func setItem(_ item: Item) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.insert(item, at: 0) }
    }

    private func run(_ url: URL, key: String, expectedBytes: Int64?, downloader: DiscoveryDownloader, op: UUID) async {
        var temp: URL?
        defer {
            if let t = temp { try? FileManager.default.removeItem(at: t) }
            inflight[key] = nil
            MirsaOperationProgress.shared.finish(op)
            finishedAt[key] = Date()
        }
        let name = url.lastPathComponent.isEmpty ? (url.host ?? "IPA") : url.lastPathComponent
        do {
            let file = try await downloader.download(url, expectedBytes: expectedBytes) { [weak self] p in
                Task { @MainActor in
                    guard let self, self.inflight[key] != nil else { return }
                    MirsaOperationProgress.shared.update(op, phase: .downloading, fraction: (expectedBytes ?? 0) > 0 ? p : nil)
                    self.setItem(Item(id: key, title: name, state: .downloading(p)))
                }
            }
            temp = file
            setItem(Item(id: key, title: name, state: .validating))
            MirsaOperationProgress.shared.update(op, phase: .preparing)
            let os = UIDevice.current.systemVersion
            let facts = try await Task.detached(priority: .userInitiated) {
                try IPAValidator.validate(file: file, expectedBundleID: nil, expectedVersion: nil, deviceOS: os)
            }.value
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            DownloadsLibrary.shared.add(ipa: file, bundleID: facts.bundleID, name: facts.displayName,
                                        version: facts.version, size: size, icon: nil)
            let item = DownloadItem(bundleID: facts.bundleID, name: facts.displayName, version: facts.version, size: size, date: Date())
            guard FileManager.default.fileExists(atPath: DownloadsLibrary.ipaURL(item).path) else {
                setItem(Item(id: key, title: facts.displayName, state: .failed(tr("Couldn't save it to Downloads.", "ما قدرت احفظه بالتنزيلات.")))); return
            }
            setItem(Item(id: key, title: facts.displayName + " " + facts.version, state: .added(bundleID: facts.bundleID, version: facts.version)))
        } catch {
            setItem(Item(id: key, title: name, state: .failed(Self.message(error))))
        }
    }

    /// A login-gated link returns HTML to the cookie-less pinned transport; say so plainly.
    static func message(_ error: Error) -> String {
        let text = error.localizedDescription
        let l = text.lowercased()
        if l.contains("zip") || l.contains("archive") || l.contains("ipa") || l.contains("web page") {
            return tr("That download needs your login or isn't a valid IPA. Mirsa never sends browser cookies to the downloader.",
                      "هالتنزيل بدو تسجيل دخول أو مو IPA صحيح. ميرسا ما بتبعت كوكيز المتصفح للتنزيل.")
        }
        return text
    }
}
