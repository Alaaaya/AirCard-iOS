import Foundation

// MARK: - URL safety policy (pure, no I/O)

/// Every network target discovery touches (metadata endpoints, download links,
/// redirect hops) goes through this policy. HTTPS only, public DNS names only.
/// IP literals are rejected outright: an IPA host is never a bare address, and
/// refusing them also covers decimal / hex / octal tricks.
/// Limit: DNS rebinding cannot be fully excluded client-side, so the policy is
/// re-applied on every redirect hop and size/time limits bound the damage.
enum DiscoveryURLPolicy {
    enum Violation: Error, Equatable, CustomStringConvertible {
        case notHTTPS, noHost, credentialsInURL, badPort, localHost, ipLiteral, tooLong
        var description: String {
            switch self {
            case .notHTTPS: return "Only https links are allowed."
            case .noHost: return "The link has no host."
            case .credentialsInURL: return "Links with embedded credentials are refused."
            case .badPort: return "Only the standard https port is allowed."
            case .localHost: return "Local or private hosts are refused."
            case .ipLiteral: return "Links that use a raw IP address are refused."
            case .tooLong: return "The link is too long."
            }
        }
    }

    static let maxURLLength = 2048

    static func check(_ url: URL) -> Violation? {
        if url.absoluteString.count > maxURLLength { return .tooLong }
        guard url.scheme?.lowercased() == "https" else { return .notHTTPS }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var host = comps.host?.lowercased(), !host.isEmpty else { return .noHost }
        if comps.user != nil || comps.password != nil { return .credentialsInURL }
        if let p = comps.port, p != 443 { return .badPort }
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return .noHost }
        if host.contains(":") || host.hasPrefix("[") { return .ipLiteral }          // IPv6 literal
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.contains(where: { $0.isEmpty }) { return .noHost }
        if labels.count < 2 { return .localHost }                                      // "localhost", "intranet", "printer"
        let tld = labels.last!
        if tld.allSatisfy({ $0.isNumber }) || tld.hasPrefix("0x") { return .ipLiteral } // 127.0.0.1, 2130706433, 0x7f.1
        let blockedSuffixes = ["local", "localhost", "internal", "lan", "home", "intranet", "corp", "private", "localdomain", "home.arpa", "arpa"]
        for s in blockedSuffixes where host == s || host.hasSuffix("." + s) { return .localHost }
        if !host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) {
            return .localHost // non-ASCII / odd characters: refuse rather than guess
        }
        return nil
    }

    static func isSafe(_ url: URL) -> Bool { check(url) == nil }
}

// MARK: - Query parsing

enum DiscoveryQuery: Equatable {
    case appStoreID(id: String, country: String?)
    case name(String)
    case unsupported(String)

    static func parse(_ raw: String) -> DiscoveryQuery {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .unsupported("Type an app name or paste an App Store link.") }
        if text.count > 300 { return .unsupported("That's too long.") }
        if text.lowercased().hasPrefix("http") || text.contains("://") {
            guard let url = URL(string: text), let host = url.host?.lowercased() else {
                return .unsupported("That link isn't valid.")
            }
            guard host == "apps.apple.com" || host == "itunes.apple.com" else {
                return .unsupported("Only App Store links are supported. For other links, add them as a source.")
            }
            if let id = appStoreID(in: url.path) ?? appStoreID(in: url.query ?? "") {
                let parts = url.pathComponents.filter { $0 != "/" }
                let cc = parts.first.flatMap { $0.count == 2 && $0.allSatisfy({ $0.isLetter }) ? $0.lowercased() : nil }
                return .appStoreID(id: id, country: cc)
            }
            return .unsupported("That App Store link has no app id.")
        }
        let lower = text.lowercased()
        if lower.hasPrefix("id"), lower.dropFirst(2).count >= 5, lower.dropFirst(2).allSatisfy({ $0.isNumber && $0.isASCII }) {
            return .appStoreID(id: String(lower.dropFirst(2)), country: nil)
        }
        if text.count >= 8, text.allSatisfy({ $0.isNumber && $0.isASCII }) {
            return .appStoreID(id: text, country: nil)
        }
        return .name(text)
    }

    private static func appStoreID(in s: String) -> String? {
        guard let r = s.range(of: #"id(\d{5,15})"#, options: .regularExpression) else { return nil }
        return String(s[r].dropFirst(2))
    }
}

// MARK: - Candidates

enum DiscoveryIdentity: String, Codable, Equatable {
    /// Bundle ID equals the one Apple's public metadata returned for the app asked for.
    case bundleVerified
    /// Matched on the name only. Could be a different app with a similar name.
    case nameOnly
    /// Metadata reference (Apple listing). No download.
    case reference
}

enum DiscoveryOrigin: String, Codable, Equatable {
    case userSource, builtInSource, appleMetadata, webBackend
}

struct DiscoveryCandidate: Identifiable, Equatable {
    var id: String { Self.makeID(sourceURL: sourceURL, bundleID: bundleID, version: version, download: downloadURL?.absoluteString) }
    let name: String
    let bundleID: String
    let developer: String
    let version: String
    let minOS: String?
    let iconURL: URL?
    let downloadURL: URL?
    let sourceName: String
    let sourceURL: String
    var origin: DiscoveryOrigin
    var identity: DiscoveryIdentity
    var score: Double = 0

    var isDownloadable: Bool { downloadURL != nil && origin != .appleMetadata }

    static func makeID(sourceURL: String, bundleID: String, version: String, download: String?) -> String {
        [sourceURL.lowercased(), bundleID.lowercased(), version, download ?? "-"].joined(separator: "|")
    }
}

/// Which sources the owner declared as author-authorized distribution points.
/// Built-in sources are NOT trusted by default; public presence is not permission.
struct DiscoveryAuthorization: Equatable {
    var authorizedSources: Set<String> = []
    static func normalize(_ s: String) -> String { s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }
    func isAuthorized(sourceURL: String) -> Bool { authorizedSources.contains(Self.normalize(sourceURL)) }
    mutating func authorize(_ sourceURL: String) { authorizedSources.insert(Self.normalize(sourceURL)) }
    mutating func revoke(_ sourceURL: String) { authorizedSources.remove(Self.normalize(sourceURL)) }
}

// MARK: - Matching

enum DiscoveryMatcher {
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func tokens(_ s: String) -> Set<String> {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 })
    }

    /// 1.0 exact, 0.85 prefix, 0.65 contains, token overlap otherwise. 0 = no match.
    static func score(query: String, name: String) -> Double {
        let q = normalize(query), n = normalize(name)
        guard !q.isEmpty, !n.isEmpty else { return 0 }
        if q == n { return 1 }
        if n.hasPrefix(q) { return 0.85 }
        if q.count >= 3 && n.contains(q) { return 0.65 }
        let qt = tokens(query), nt = tokens(name)
        guard !qt.isEmpty else { return 0 }
        let overlap = Double(qt.intersection(nt).count) / Double(qt.count)
        return overlap >= 1 ? 0.6 : (overlap >= 0.67 ? 0.5 : 0)
    }

    static let minScore = 0.5

    static func rank(_ list: [DiscoveryCandidate], query: String) -> [DiscoveryCandidate] {
        list.map { var c = $0; c.score = max(c.score, score(query: query, name: c.name)); return c }
            .filter { $0.score >= minScore || $0.identity == .bundleVerified }
            .sorted { ($0.score, $0.version.compare($1.version, options: .numeric) == .orderedDescending ? 1 : 0)
                    > ($1.score, $1.version.compare($0.version, options: .numeric) == .orderedDescending ? 1 : 0) }
    }

    /// Same source + bundle + version + url collapses. Different sources never collapse.
    static func dedupe(_ list: [DiscoveryCandidate]) -> [DiscoveryCandidate] {
        var seen = Set<String>(); var out: [DiscoveryCandidate] = []
        for c in list where seen.insert(c.id).inserted { out.append(c) }
        return out
    }

    /// True when the results point at more than one distinct app (bundle ID). The UI then
    /// must show every card and never pick one for the user.
    static func isAmbiguous(_ list: [DiscoveryCandidate]) -> Bool {
        Set(list.map { $0.bundleID.lowercased() }).count > 1
    }
}

// MARK: - Provider contract

struct DiscoverySourceSnapshot: Equatable {
    struct App: Equatable {
        let name: String, bundleID: String, developer: String, version: String
        let iconURL: URL?, downloadURL: URL
    }
    let name: String
    let url: String
    let isBuiltIn: Bool
    let apps: [App]
}

enum ProviderStatus: Equatable {
    case ok(count: Int)
    case unavailable(String)   // not configured / failed
    case blocked(String)       // not possible in this build
}

struct ProviderReport: Equatable { let provider: String; var status: ProviderStatus }

struct ProviderResult { var candidates: [DiscoveryCandidate]; var report: ProviderReport }

/// Pure aggregation over the sources the user already has.
enum SourcesDiscovery {
    static func search(_ snaps: [DiscoverySourceSnapshot], name: String?, bundleID: String?) -> [DiscoveryCandidate] {
        var out: [DiscoveryCandidate] = []
        for s in snaps {
            for a in s.apps {
                let byBundle = bundleID.map { !$0.isEmpty && a.bundleID.caseInsensitiveCompare($0) == .orderedSame } ?? false
                let nameScore = name.map { DiscoveryMatcher.score(query: $0, name: a.name) } ?? 0
                guard byBundle || nameScore >= DiscoveryMatcher.minScore else { continue }
                guard DiscoveryURLPolicy.isSafe(a.downloadURL) else { continue }
                out.append(DiscoveryCandidate(
                    name: a.name, bundleID: a.bundleID, developer: a.developer, version: a.version, minOS: nil,
                    iconURL: a.iconURL.flatMap { DiscoveryURLPolicy.isSafe($0) ? $0 : nil }, downloadURL: a.downloadURL,
                    sourceName: s.name, sourceURL: s.url,
                    origin: s.isBuiltIn ? .builtInSource : .userSource,
                    identity: byBundle ? .bundleVerified : .nameOnly,
                    score: byBundle ? 1 : nameScore))
            }
        }
        return DiscoveryMatcher.dedupe(out)
    }
}
