import Foundation

/// Pure navigation / response policy for the in-app browser. No UIKit, so it is
/// unit-testable without a simulator. Everything that looks like an IPA is handed
/// to the pinned Discovery transport; everything else stays ordinary web navigation.
enum MirsaBrowserPolicy {
    enum Decision: Equatable {
        case allow
        case download(URL)
        case refuse(String)
    }

    /// MIME types an IPA host may legitimately use. HTML-ish types are never candidates.
    static let ipaMIMEs: Set<String> = ["application/x-itunes-ipa", "application/x-ipa"]
    static let genericMIMEs: Set<String> = ["application/octet-stream", "binary/octet-stream", "application/zip",
                                           "application/x-zip-compressed", "application/x-zip", "application/force-download",
                                           "application/download"]

    static func mime(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let m = raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return m.isEmpty ? nil : m
    }

    static func isPageMIME(_ m: String) -> Bool {
        m.hasPrefix("text/") || m.contains("html") || m.contains("xml") || m.contains("json") || m.hasPrefix("image/")
            || m.hasPrefix("video/") || m.hasPrefix("audio/") || m == "application/pdf"
    }

    /// filename= / filename*= from a Content-Disposition header.
    static func dispositionFilename(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var plain: String?
        for p in parts {
            let lower = p.lowercased()
            if lower.hasPrefix("filename*=") {
                var v = String(p.dropFirst("filename*=".count))
                if let r = v.range(of: "''") { v = String(v[r.upperBound...]) }
                return v.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).removingPercentEncoding
            }
            if lower.hasPrefix("filename=") {
                plain = String(p.dropFirst("filename=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return plain
    }

    private static func isIPAName(_ name: String?) -> Bool { name?.lowercased().hasSuffix(".ipa") == true }

    /// Decision for a main-frame response (the MIME / disposition gate).
    static func decide(response url: URL, mimeType: String?, contentDisposition: String?, canShow: Bool) -> Decision {
        let m = mime(mimeType)
        // HTML (or any displayable type) is a page, even when it pretends to be x.ipa.
        if let m, isPageMIME(m) { return .allow }
        let nameIsIPA = isIPAName(dispositionFilename(contentDisposition))
        let urlIsIPA = url.path.lowercased().hasSuffix(".ipa")
        let ipaMIME = m.map { ipaMIMEs.contains($0) } ?? false
        let generic = m == nil || m.map { genericMIMEs.contains($0) } == true
        let candidate = nameIsIPA || ipaMIME || (urlIsIPA && generic)
        if candidate { return gate(url) }
        if !canShow { return .refuse("This file isn't an IPA, so it wasn't downloaded.") }
        return .allow
    }

    /// Decision for a navigation request before any response exists.
    static func decide(navigation url: URL) -> Decision {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" { return .allow }
        guard scheme == "https" || scheme == "http" else { return .refuse("Links like \(scheme):// can't be opened here.") }
        if url.path.lowercased().hasSuffix(".ipa") && scheme == "http" { return .refuse(DiscoveryURLPolicy.Violation.notHTTPS.description) }
        return .allow
    }

    static func gate(_ url: URL) -> Decision {
        if let v = DiscoveryURLPolicy.check(url) { return .refuse(v.description) }
        return .download(url)
    }

    /// Turns what the user typed into a browsable URL. Only http(s); bare hosts become https.
    static func address(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if let u = URL(string: t), let s = u.scheme?.lowercased(), u.host != nil {
            return (s == "https" || s == "http") ? u : nil
        }
        guard t.contains("."), !t.contains("://"), let u = URL(string: "https://" + t), u.host != nil else { return nil }
        return u
    }

    /// Same file reached through navigation and response must collapse to one queue entry.
    static func dedupeKey(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.fragment = nil
        c.host = c.host?.lowercased()
        return c.string ?? url.absoluteString
    }
}
