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
final class SafeMetadataHTTP: NSObject, DiscoveryHTTP, DiscoveryAuthHTTP, URLSessionTaskDelegate {
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

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (Data, Int) {
        if let v = DiscoveryURLPolicy.check(url) { throw DiscoveryHTTPError(message: v.description) }
        guard body.count <= 4096 else { throw DiscoveryHTTPError(message: "Request too large.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        guard let h = resp as? HTTPURLResponse, data.count <= Self.maxBody else { throw DiscoveryHTTPError(message: "Bad response.") }
        return (data, h.statusCode)
    }

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
            let l = parse(data).filter { listing in
                guard !listing.name.isEmpty, !listing.bundleID.isEmpty else { return false }
                if case .appStoreID(let id, _) = q { return listing.trackID == id }
                if case .name(let name) = q { return DiscoveryMatcher.score(query: name, name: listing.name) >= DiscoveryMatcher.minScore }
                return false
            }
            return (l, ProviderReport(provider: "Apple metadata", status: .ok(count: l.count)))
        } catch {
            return ([], ProviderReport(provider: "Apple metadata", status: .unavailable(error.localizedDescription)))
        }
    }
}

// MARK: - Configurable web backend (optional)

/// The owner's search backend (Supabase Edge Function behind anonymous Auth). Contract: GET <project>/functions/v1/discovery-search?q=<name>&bundle=<id>
/// with "Authorization: Bearer <per-install user JWT>" returns {"results":[...]}.
/// Only the project URL and the PUBLIC publishable/anon key are configured. Nothing secret is compiled in or accepted.
struct WebBackendConfig: Equatable {
    var projectURL: URL?
    var publishableKey: String?
    static let projectKey = "mirsa.discovery.web.project"
    static let publishableKeyKey = "mirsa.discovery.web.publishable"

    var endpoint: URL? { projectURL?.appendingPathComponent("functions/v1/discovery-search") }
    var isConfigured: Bool { projectURL != nil && !(publishableKey ?? "").isEmpty && !WebBackendConfig.looksSecret(publishableKey ?? "") }

    /// Public values only (project URL + publishable key). Safe to ship; the key grants nothing beyond anonymous sign-in.
    static let defaultProject = "https://hirebeofomiyumwysppj.supabase.co"
    static let defaultPublishableKey = "sb_publishable_o3dt8riPdpZHazjpPgG25Q_HgGfnub5"

    static func load(defaults: UserDefaults = .standard) -> WebBackendConfig {
        let u = (defaults.string(forKey: projectKey) ?? defaultProject)
        let k = defaults.string(forKey: publishableKeyKey) ?? defaultPublishableKey
        return WebBackendConfig(projectURL: URL(string: u).flatMap { DiscoveryURLPolicy.isSafe($0) ? $0 : nil }, publishableKey: k)
    }
}

enum WebBackendProvider {
    static func parse(_ data: Data) -> [DiscoveryCandidate] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.prefix(30).compactMap { r in
            guard let name = r["name"] as? String else { return nil }
            let bid = (r["bundleId"] as? String) ?? ""
            let searchable = [name, (r["pageURL"] as? String) ?? "", (r["downloadURL"] as? String) ?? ""].joined(separator: " ").lowercased()
            if searchable.range(of: #"android|\bapk(?:s|m|x)?\b|apkpure|apkmirror|apkcombo|uptodown|play\.google\.com"#, options: .regularExpression) != nil { return nil }
            let dlRaw = (r["downloadURL"] as? String).flatMap(URL.init(string:))
            if dlRaw != nil, !DiscoveryURLPolicy.isSafe(dlRaw!) { return nil }
            let dl = dlRaw
            if let source = r["sourceURL"] as? String {
                guard let u = URL(string: source), DiscoveryURLPolicy.isSafe(u) else { return nil }
            }
            if let page = r["pageURL"] as? String {
                guard let u = URL(string: page), DiscoveryURLPolicy.isSafe(u) else { return nil }
            }
            if searchable.range(of: #"\b(decrypted|cracked|crack|decrypt|drm)\b"#, options: .regularExpression) != nil { return nil }
            let pageRaw = (r["pageURL"] as? String).flatMap(URL.init(string:)).flatMap { DiscoveryURLPolicy.isSafe($0) ? $0 : nil }
            if dl == nil && pageRaw == nil { return nil }
            let icon = (r["iconURL"] as? String).flatMap(URL.init(string:)).flatMap { DiscoveryURLPolicy.isSafe($0) ? $0 : nil }
            return DiscoveryCandidate(name: name, bundleID: bid, developer: (r["developer"] as? String) ?? "",
                                      version: (r["version"] as? String) ?? "", minOS: r["minOS"] as? String, iconURL: icon,
                                      downloadURL: dl, sourceName: (r["sourceName"] as? String) ?? ((dl ?? pageRaw)?.host ?? "web"),
                                      sourceURL: (r["sourceURL"] as? String) ?? (dl ?? pageRaw)!.absoluteString,
                                      origin: .webBackend, identity: dl == nil ? .reference : .nameOnly)
        }
    }

    static func search(_ config: WebBackendConfig, name: String?, bundleID: String?, auth: DiscoveryTokenProvider?, http: DiscoveryHTTP) async -> ProviderResult {
        func fail(_ m: String) -> ProviderResult { ProviderResult(candidates: [], report: ProviderReport(provider: "Web search", status: .unavailable(m))) }
        guard config.isConfigured, let endpoint = config.endpoint, let auth else {
            return fail("Not configured. Add your project URL and public key to enable it.")
        }
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        if let name { items.append(URLQueryItem(name: "q", value: name)) }
        if let bundleID { items.append(URLQueryItem(name: "bundle", value: bundleID)) }
        c?.queryItems = items
        guard let url = c?.url else { return fail("Bad backend URL.") }
        do {
            var force = false
            // At most two requests: the second only after a 401 with a freshly refreshed token. 429 and 5xx are never retried.
            for _ in 0..<2 {
                let token = try await auth.token(forceRefresh: force)
                let (data, code) = try await http.get(url, headers: ["Authorization": "Bearer " + token])
                if code == 401, !force { force = true; continue }
                if code == 429 { return fail("Search limit reached for now. Try again later.") }
                guard (200..<300).contains(code) else { return fail("Backend answered \(code).") }
                let list = parse(data)
                return ProviderResult(candidates: list, report: ProviderReport(provider: "Web search", status: .ok(count: list.count)))
            }
            return fail("Sign-in was rejected by the backend.")
        } catch {
            return fail(error.localizedDescription)
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
    static let emptyMessage = "ما لقيت IPA لهالتطبيق"
    static func run(input: String, sources: [DiscoverySourceSnapshot], web: WebBackendConfig, auth: DiscoveryTokenProvider? = nil, http: DiscoveryHTTP, verifier: DiscoveryIPAVerifying = DiscoveryIPAVerifier()) async -> DiscoveryOutcome {
        let q = DiscoveryQuery.parse(input)
        if case .unsupported(let why) = q {
            return DiscoveryOutcome(query: q, candidates: [], reports: [], ambiguous: false, note: why)
        }
        let apple = await AppleMetadata.resolve(q, http: http)
        var reports = [apple.report]
        if case .appStoreID = q, apple.listings.isEmpty {
            return DiscoveryOutcome(query: q, candidates: [], reports: reports, ambiguous: false, note: emptyMessage)
        }
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
        reports.append(ProviderReport(provider: "Your sources", status: .ok(count: found.count)))

        let webRes = await WebBackendProvider.search(web, name: nameQuery ?? apple.listings.first?.name,
                                                     bundleID: bundleIDs.first, auth: auth, http: http)
        reports.append(webRes.report)
        found += webRes.candidates // Search metadata is not proof of an IPA archive identity.
        reports.append(TelegramProvider.report)

        let matchingName = nameQuery ?? apple.listings.first?.name ?? ""
        let expectedBundle = bundleIDs.first
        let relevant = DiscoveryMatcher.dedupe(found).filter { c in
            guard c.isDownloadable else { return false }
            if let b = expectedBundle, !c.bundleID.isEmpty, c.bundleID.caseInsensitiveCompare(b) != .orderedSame { return false }
            return DiscoveryMatcher.score(query: matchingName, name: c.name) >= DiscoveryMatcher.minScore ||
                (expectedBundle != nil && c.bundleID.caseInsensitiveCompare(expectedBundle!) == .orderedSame)
        }
        // A suffix or a search provider's JSON is not evidence. Validate the actual archive
        // before exposing a card. Keep sequential and bounded to avoid parallel large downloads.
        var all: [DiscoveryCandidate] = []
        for c in relevant.prefix(6) {
            if let verified = await verifier.verify(c, expectedBundleID: expectedBundle, queryName: matchingName) {
                all.append(verified)
            }
        }
        let ambiguous = DiscoveryMatcher.isAmbiguous(all)
        let note: String? = all.isEmpty ? emptyMessage : nil
        return DiscoveryOutcome(query: q, candidates: all, reports: reports, ambiguous: ambiguous, note: note)
    }
}


// Actual archive verification, not HEAD, MIME type, URL suffix, or backend assertions.
protocol DiscoveryIPAVerifying {
    func verify(_ candidate: DiscoveryCandidate, expectedBundleID: String?, queryName: String) async -> DiscoveryCandidate?
}

struct DiscoveryIPAVerifier: DiscoveryIPAVerifying {
    func verify(_ candidate: DiscoveryCandidate, expectedBundleID: String?, queryName: String) async -> DiscoveryCandidate? {
        guard let url = candidate.downloadURL, DiscoveryURLPolicy.isSafe(url) else { return nil }
        var limits = DiscoveryDownloader.Limits()
        limits.maxBytes = 256 * 1024 * 1024
        limits.requestTimeout = 10
        limits.totalTimeout = 30
        let downloader = DiscoveryDownloader(limits: limits)
        do {
            let file = try await downloader.download(url) { _ in }
            defer { try? FileManager.default.removeItem(at: file) }
            return try Self.validated(candidate, file: file, expectedBundleID: expectedBundleID, queryName: queryName)
        } catch { return nil }
    }

    static func validated(_ c: DiscoveryCandidate, file: URL, expectedBundleID: String?, queryName: String) throws -> DiscoveryCandidate? {
        var limits = IPALimits()
        limits.maxFileSize = 256 * 1024 * 1024
        limits.maxExecutable = 256 * 1024 * 1024
        let facts = try IPAValidator.validate(file: file, expectedBundleID: expectedBundleID,
            expectedVersion: c.version.isEmpty ? nil : c.version, deviceOS: nil, limits: limits)
        guard expectedBundleID != nil || DiscoveryMatcher.score(query: queryName, name: facts.displayName) >= DiscoveryMatcher.minScore else { return nil }
        return DiscoveryCandidate(name: facts.displayName, bundleID: facts.bundleID, developer: c.developer,
            version: facts.version, minOS: facts.minOS, iconURL: c.iconURL, downloadURL: c.downloadURL,
            sourceName: c.sourceName, sourceURL: c.sourceURL, origin: c.origin, identity: .bundleVerified, score: 1)
    }
}
