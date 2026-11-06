import Foundation

// MARK: - HTTP abstraction (injectable for tests)

protocol DiscoveryHTTP {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int)
}

struct DiscoveryHTTPError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Metadata fetcher: HTTPS policy on the request and every redirect, small bounded bodies.
final class SafeMetadataHTTP: NSObject, DiscoveryHTTP, URLSessionTaskDelegate {
    static let maxBody = 2 * 1024 * 1024
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 25
        c.httpCookieStorage = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    private var hops: [Int: Int] = [:]
    private let lock = NSLock()

    func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, Int) {
        if let v = DiscoveryURLPolicy.check(url) { throw DiscoveryHTTPError(message: v.description) }
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (bytes, resp) = try await session.bytes(for: req)
        guard let h = resp as? HTTPURLResponse else { throw DiscoveryHTTPError(message: "Bad response.") }
        if h.expectedContentLength > Int64(Self.maxBody) { throw DiscoveryHTTPError(message: "Response too large.") }
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count > Self.maxBody { throw DiscoveryHTTPError(message: "Response too large.") }
        }
        return (data, h.statusCode)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); let n = (hops[task.taskIdentifier] ?? 0) + 1; hops[task.taskIdentifier] = n; lock.unlock()
        guard n <= 4, let u = request.url, DiscoveryURLPolicy.isSafe(u) else { task.cancel(); completionHandler(nil); return }
        completionHandler(request)
    }
}

// MARK: - Apple public metadata (identity only, never an IPA)

struct AppleListing: Equatable {
    let trackID: String, name: String, bundleID: String, developer: String
    let version: String, minOS: String?, iconURL: URL?, storeURL: URL?
}

enum AppleMetadata {
    static func lookupURL(id: String, country: String?) -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/lookup")
        c?.queryItems = [URLQueryItem(name: "id", value: id)] + (country.map { [URLQueryItem(name: "country", value: $0)] } ?? [])
        return c?.url
    }
    static func searchURL(term: String, country: String?) -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")
        c?.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "entity", value: "software"),
                         URLQueryItem(name: "limit", value: "8"), URLQueryItem(name: "country", value: country ?? "us")]
        return c?.url
    }

    static func parse(_ data: Data) -> [AppleListing] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let bid = r["bundleId"] as? String, let name = r["trackName"] as? String else { return nil }
            let id = (r["trackId"] as? NSNumber)?.stringValue ?? (r["trackId"] as? String) ?? ""
            func url(_ k: String) -> URL? { (r[k] as? String).flatMap(URL.init(string:)).flatMap { DiscoveryURLPolicy.isSafe($0) ? $0 : nil } }
            return AppleListing(trackID: id, name: name, bundleID: bid, developer: (r["artistName"] as? String) ?? "",
                                version: (r["version"] as? String) ?? "", minOS: r["minimumOsVersion"] as? String,
                                iconURL: url("artworkUrl512") ?? url("artworkUrl100"), storeURL: url("trackViewUrl"))
        }
    }

    static func candidate(_ l: AppleListing) -> DiscoveryCandidate {
        DiscoveryCandidate(name: l.name, bundleID: l.bundleID, developer: l.developer, version: l.version, minOS: l.minOS,
                           iconURL: l.iconURL, downloadURL: nil, sourceName: "App Store (metadata only)",
                           sourceURL: l.storeURL?.absoluteString ?? "https://apps.apple.com", origin: .appleMetadata, identity: .reference)
    }

    static func resolve(_ q: DiscoveryQuery, http: DiscoveryHTTP) async -> (listings: [AppleListing], report: ProviderReport) {
        let url: URL?
        switch q {
        case .appStoreID(let id, let cc): url = lookupURL(id: id, country: cc)
        case .name(let n): url = searchURL(term: n, country: nil)
        case .unsupported: url = nil
        }
        guard let url else { return ([], ProviderReport(provider: "Apple metadata", status: .unavailable("Nothing to look up."))) }
        do {
            let (data, code) = try await http.get(url, headers: [:])
            if code == 429 || code == 403 { return ([], ProviderReport(provider: "Apple metadata", status: .unavailable("Apple is rate limiting lookups. Try again in a minute."))) }
            guard (200..<300).contains(code) else { return ([], ProviderReport(provider: "Apple metadata", status: .unavailable("Apple answered \(code)."))) }
            let l = parse(data)
            return (l, ProviderReport(provider: "Apple metadata", status: .ok(count: l.count)))
        } catch {
            return ([], ProviderReport(provider: "Apple metadata", status: .unavailable(error.localizedDescription)))
        }
    }
}

// MARK: - Configurable web backend (optional)

/// A backend the owner runs and configures. Contract: GET <endpoint>?q=<name>&bundle=<id>
/// with optional "Authorization: Bearer <token>" returns
/// {"results":[{"name","bundleId","developer","version","iconURL","downloadURL","sourceName","sourceURL"}]}.
/// No endpoint configured means this provider reports "not configured". No secret is compiled in.
struct WebBackendConfig: Equatable {
    var endpoint: URL?
    var token: String?
    static let endpointKey = "mirsa.discovery.web.endpoint"

    static func load(defaults: UserDefaults = .standard, token: String? = nil) -> WebBackendConfig {
        let u = defaults.string(forKey: endpointKey).flatMap(URL.init(string:))
        return WebBackendConfig(endpoint: u.flatMap { DiscoveryURLPolicy.isSafe($0) ? $0 : nil }, token: token)
    }
}

enum WebBackendProvider {
    static func parse(_ data: Data) -> [DiscoveryCandidate] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.prefix(30).compactMap { r in
            guard let name = r["name"] as? String, let bid = r["bundleId"] as? String,
                  let dl = (r["downloadURL"] as? String).flatMap(URL.init(string:)), DiscoveryURLPolicy.isSafe(dl) else { return nil }
            let icon = (r["iconURL"] as? String).flatMap(URL.init(string:)).flatMap { DiscoveryURLPolicy.isSafe($0) ? $0 : nil }
            return DiscoveryCandidate(name: name, bundleID: bid, developer: (r["developer"] as? String) ?? "",
                                      version: (r["version"] as? String) ?? "", minOS: r["minOS"] as? String, iconURL: icon,
                                      downloadURL: dl, sourceName: (r["sourceName"] as? String) ?? (dl.host ?? "web"),
                                      sourceURL: (r["sourceURL"] as? String) ?? dl.absoluteString,
                                      origin: .webBackend, identity: .nameOnly)
        }
    }

    static func search(_ config: WebBackendConfig, name: String?, bundleID: String?, http: DiscoveryHTTP) async -> ProviderResult {
        guard let endpoint = config.endpoint else {
            return ProviderResult(candidates: [], report: ProviderReport(provider: "Web search", status: .unavailable("Not configured. Set a search backend to enable it.")))
        }
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var items = c?.queryItems ?? []
        if let name { items.append(URLQueryItem(name: "q", value: name)) }
        if let bundleID { items.append(URLQueryItem(name: "bundle", value: bundleID)) }
        c?.queryItems = items
        guard let url = c?.url else { return ProviderResult(candidates: [], report: ProviderReport(provider: "Web search", status: .unavailable("Bad backend URL."))) }
        do {
            let (data, code) = try await http.get(url, headers: config.token.map { ["Authorization": "Bearer " + $0] } ?? [:])
            guard (200..<300).contains(code) else {
                return ProviderResult(candidates: [], report: ProviderReport(provider: "Web search", status: .unavailable("Backend answered \(code).")))
            }
            let list = parse(data)
            return ProviderResult(candidates: list, report: ProviderReport(provider: "Web search", status: .ok(count: list.count)))
        } catch {
            return ProviderResult(candidates: [], report: ProviderReport(provider: "Web search", status: .unavailable(error.localizedDescription)))
        }
    }
}

enum TelegramProvider {
    static let report = ProviderReport(provider: "Telegram", status: .blocked("Needs a signed-in Telegram account (MTProto). Not available in Mirsa."))
}

// MARK: - Orchestration

struct DiscoveryOutcome {
    var query: DiscoveryQuery
    var candidates: [DiscoveryCandidate]
    var reports: [ProviderReport]
    var ambiguous: Bool
    var note: String?
}

enum DiscoveryEngine {
    static func run(input: String, sources: [DiscoverySourceSnapshot], web: WebBackendConfig, http: DiscoveryHTTP) async -> DiscoveryOutcome {
        let q = DiscoveryQuery.parse(input)
        if case .unsupported(let why) = q {
            return DiscoveryOutcome(query: q, candidates: [], reports: [], ambiguous: false, note: why)
        }
        let apple = await AppleMetadata.resolve(q, http: http)
        var reports = [apple.report]
        var identities = apple.listings.map(AppleMetadata.candidate)
        var bundleIDs: [String] = []
        var nameQuery: String?
        switch q {
        case .appStoreID: bundleIDs = apple.listings.map { $0.bundleID }
        case .name(let n): nameQuery = n; bundleIDs = []
        case .unsupported: break
        }

        // Sources: by every resolved bundle ID, plus name when we were given one.
        var found: [DiscoveryCandidate] = []
        if bundleIDs.isEmpty {
            found += SourcesDiscovery.search(sources, name: nameQuery, bundleID: nil)
        } else {
            for b in bundleIDs { found += SourcesDiscovery.search(sources, name: apple.listings.first { $0.bundleID == b }?.name, bundleID: b) }
        }
        // For name queries, a source hit whose bundle ID equals an Apple result is bundle-verified.
        if nameQuery != nil {
            let apple = Set(apple.listings.map { $0.bundleID.lowercased() })
            found = found.map { var c = $0; if apple.contains(c.bundleID.lowercased()) { c.identity = .bundleVerified }; return c }
        }
        reports.append(ProviderReport(provider: "Your sources", status: .ok(count: found.count)))

        let webRes = await WebBackendProvider.search(web, name: nameQuery ?? apple.listings.first?.name,
                                                     bundleID: bundleIDs.first, http: http)
        reports.append(webRes.report)
        found += webRes.candidates.map { var c = $0; if bundleIDs.contains(where: { $0.caseInsensitiveCompare(c.bundleID) == .orderedSame }) { c.identity = .bundleVerified }; return c }
        reports.append(TelegramProvider.report)

        var downloadable = DiscoveryMatcher.dedupe(found)
        downloadable = nameQuery.map { DiscoveryMatcher.rank(downloadable, query: $0) } ?? downloadable.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }

        // Apple identity cards show only when no downloadable candidate carries that bundle ID.
        let covered = Set(downloadable.map { $0.bundleID.lowercased() })
        identities = identities.filter { !covered.contains($0.bundleID.lowercased()) }
        let all = downloadable + identities
        let ambiguous = DiscoveryMatcher.isAmbiguous(all)
        var note: String?
        if downloadable.isEmpty { note = "Found no downloadable copy in your sources." }
        else if ambiguous { note = "More than one app matches. Pick the right one yourself." }
        return DiscoveryOutcome(query: q, candidates: all, reports: reports, ambiguous: ambiguous, note: note)
    }
}
