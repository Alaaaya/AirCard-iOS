import Foundation

/// Per-app launch + crash telemetry: bounded .ips parser, type-aware redaction,
/// bounded store. Pure Foundation (testable without UI). No symbolication is faked:
/// frames are shown as the report gives them; offline symbolication is only
/// attempted by the caller with matching-UUID images (see MirsaCrashSymbolizer).
struct MirsaCrashFrame: Codable, Equatable {
    var index: Int
    var image: String?
    var symbol: String?
    var offset: Int?
    var symbolicated: Bool { symbol != nil }
}

enum MirsaCrashProvenance: String, Codable, Equatable { case userImport, pairedDevice }

struct MirsaCrashReport: Codable, Equatable, Identifiable {
    var id: String
    var bundleID: String?
    var appName: String?
    var version: String?
    var date: Date?
    var exceptionType: String?
    var signal: String?
    var terminationReason: String?
    var crashedThread: Int?
    var frames: [MirsaCrashFrame]
    var imageUUIDs: [String: String]   // image name -> UUID (for offline symbolication)
    var importedManually: Bool
    var provenance: MirsaCrashProvenance? = nil

    /// Best available human reason, never invented.
    var readableReason: String {
        var p: [String] = []
        if let e = exceptionType { p.append(e) }
        if let s = signal { p.append(s) }
        if let t = terminationReason, !t.isEmpty { p.append(t) }
        return p.isEmpty ? "No reason recorded in this report" : p.joined(separator: " / ")
    }
}

enum MirsaCrashParseError: Error, Equatable { case tooLarge, empty, malformed, tooDeep, notUTF8 }

enum MirsaCrashParser {
    static let maxBytes = 4 * 1024 * 1024
    static let maxDepth = 24
    static let maxFrames = 200
    static let maxImages = 600
    static let maxString = 512

    static func parse(_ data: Data) throws -> MirsaCrashReport {
        if data.isEmpty { throw MirsaCrashParseError.empty }
        if data.count > maxBytes { throw MirsaCrashParseError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw MirsaCrashParseError.notUTF8 }
        if text.contains("\u{FFFD}") { throw MirsaCrashParseError.notUTF8 }
        try preflightDepth(data)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw MirsaCrashParseError.empty }
        // Format A: header JSON line, newline, payload JSON. Format B: single JSON object.
        var header: [String: Any] = [:]
        var payload: [String: Any]
        if let nl = trimmed.firstIndex(of: "\n") {
            let first = String(trimmed[..<nl]), rest = String(trimmed[trimmed.index(after: nl)...])
            if let h = try? obj(first), let p = try? obj(rest) { header = h; payload = p }
            else { payload = try obj(trimmed) }
        } else { payload = try obj(trimmed) }
        if payload["threads"] == nil, payload["exception"] == nil, payload["procName"] == nil, header.isEmpty == false {
            // header-only edge: still produce what we can
        }
        try checkDepth(payload, 0)
        let bundle = clip((payload["bundleID"] as? String) ?? ((payload["bundleInfo"] as? [String: Any])?["CFBundleIdentifier"] as? String) ?? (header["bundleID"] as? String))
        let name = clip((header["app_name"] as? String) ?? (payload["procName"] as? String))
        let ver = clip((header["app_version"] as? String) ?? ((payload["bundleInfo"] as? [String: Any])?["CFBundleShortVersionString"] as? String))
        let ex = payload["exception"] as? [String: Any]
        let term = payload["termination"] as? [String: Any]
        var images: [(name: String, uuid: String?)] = []
        for (i, im) in ((payload["usedImages"] as? [Any]) ?? []).prefix(maxImages).enumerated() {
            _ = i
            if let d = im as? [String: Any] {
                let n = ((d["name"] as? String) ?? (d["path"] as? String).map { ($0 as NSString).lastPathComponent }) ?? "?"
                images.append((clip(n) ?? "?", d["uuid"] as? String))
            }
        }
        var crashed = payload["faultingThread"] as? Int
        let threads = (payload["threads"] as? [Any]) ?? []
        if crashed == nil {
            for (i, t) in threads.enumerated() { if let d = t as? [String: Any], (d["triggered"] as? Bool) == true { crashed = i; break } }
        }
        var frames: [MirsaCrashFrame] = []
        if let c = crashed, c >= 0, c < threads.count, let t = threads[c] as? [String: Any] {
            for (i, f) in ((t["frames"] as? [Any]) ?? []).prefix(maxFrames).enumerated() {
                guard let fd = f as? [String: Any] else { continue }
                var imgName: String?
                if let ii = fd["imageIndex"] as? Int, ii >= 0, ii < images.count { imgName = images[ii].name }
                frames.append(MirsaCrashFrame(index: i, image: imgName, symbol: clip(fd["symbol"] as? String), offset: fd["imageOffset"] as? Int))
            }
        }
        var uuids: [String: String] = [:]
        for im in images { if let u = im.uuid { uuids[im.name] = u } }
        var date: Date?
        if let ts = (header["timestamp"] as? String) ?? (payload["captureTime"] as? String) { date = parseDate(ts) }
        let any = bundle != nil || name != nil || !frames.isEmpty || ex != nil || term != nil
        if !any { throw MirsaCrashParseError.malformed }
        let sig = (ex?["signal"] as? String)
        let id = clip((header["incident_id"] as? String) ?? (payload["incident"] as? String)) ?? UUID().uuidString
        return MirsaCrashReport(id: id, bundleID: bundle, appName: name, version: ver, date: date,
                                exceptionType: clip(ex?["type"] as? String), signal: clip(sig),
                                terminationReason: clip((term?["indicator"] as? String) ?? (term?["namespace"] as? String)),
                                crashedThread: crashed, frames: frames, imageUUIDs: uuids, importedManually: true)
    }

    /// String-aware bracket depth scan on raw bytes, BEFORE JSONSerialization allocates anything.
    /// For the header+payload format each line is scanned independently, so depth is per document.
    static func preflightDepth(_ data: Data) throws {
        var depth = 0, inStr = false, esc = false
        for b in data {
            if inStr { if esc { esc = false } else if b == 0x5C { esc = true } else if b == 0x22 { inStr = false }; continue }
            switch b {
            case 0x22: inStr = true
            case 0x5B, 0x7B: depth += 1; if depth > maxDepth { throw MirsaCrashParseError.tooDeep }
            case 0x5D, 0x7D: depth = max(0, depth - 1)
            default: break
            }
        }
    }
    private static func obj(_ s: String) throws -> [String: Any] {
        guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d), let dict = o as? [String: Any] else { throw MirsaCrashParseError.malformed }
        return dict
    }
    private static func checkDepth(_ v: Any, _ d: Int) throws {
        if d > maxDepth { throw MirsaCrashParseError.tooDeep }
        if let a = v as? [Any] { for x in a.prefix(2000) { try checkDepth(x, d + 1) } }
        else if let m = v as? [String: Any] { for x in m.values { try checkDepth(x, d + 1) } }
    }
    private static func clip(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return s.count > maxString ? String(s.prefix(maxString)) : s
    }
    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss.SSS Z", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss.SSS xx"] { f.dateFormat = fmt; if let d = f.date(from: s) { return d } }
        return ISO8601DateFormatter().date(from: s)
    }
}

/// Type-aware redaction: keeps symbol/frame names, removes paths, user names,
/// ids, emails, URLs, tokens.
enum MirsaRedactor {
    private static let rules: [(NSRegularExpression, String)] = {
        let p: [(String, String)] = [
            ("https?://[^\\s\"'<>]+", "<url>"),
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<email>"),
            ("(?i)(bearer|token|authorization|password|passwd|secret|apikey|api_key)([\"'\\s:=]+)[^\\s\"',;]+", "$1$2<redacted>"),
            ("eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]*", "<jwt>"),
            ("/private/var/mobile/Containers/(Data|Shared|Bundle)/[A-Za-z0-9-]+/(Application/[A-Za-z0-9-]+/)?", "<container>/"),
            ("/var/mobile/Containers/(Data|Shared|Bundle)/[A-Za-z0-9-]+/(Application/[A-Za-z0-9-]+/)?", "<container>/"),
            ("/(Users|home)/[^/\\s]+", "/$1/<user>"),
            ("/var/mobile/[^\\s]*", "<path>"),
            ("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", "<uuid>"),
            ("\\b[0-9A-Fa-f]{40}\\b|\\b[0-9A-Fa-f]{25,}\\b", "<id>"),
        ]
        return p.compactMap { try? NSRegularExpression(pattern: $0.0) }.enumerated().map { ($0.element, p[$0.offset].1) }
    }()

    static func redact(_ s: String) -> String {
        var out = String(s.prefix(20_000))
        for (re, t) in rules { out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: t) }
        return out
    }

    /// Share/copy text: redacted by default, frames and symbols kept.
    static func shareText(_ r: MirsaCrashReport, redacted: Bool = true) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium
        var l: [String] = ["App: \(r.appName ?? r.bundleID ?? "unknown") \(r.version ?? "")",
                           "Bundle: \(r.bundleID ?? "unknown")",
                           "Time: \(r.date.map { f.string(from: $0) } ?? "unknown")",
                           "Reason: \(r.readableReason)", "Stack (crashed thread \(r.crashedThread.map(String.init) ?? "?")):"]
        for fr in r.frames.prefix(60) {
            l.append("\(fr.index)  \(fr.image ?? "?")  \(fr.symbol ?? "unsymbolicated")\(fr.offset.map { " +\($0)" } ?? "")")
        }
        let t = l.joined(separator: "\n")
        return redacted ? redact(t) : t
    }
}

// MARK: - Launch records + store

/// containerAttempt = Mirsa asked the container to start the app (GuestLoader NSLog 'launching' proves ATTEMPT only,
/// not startup, success, termination or crash). Home-screen launches are unknown. Never infer a crash from an unfinished attempt.
enum MirsaLaunchSource: String, Codable { case containerAttempt }

struct MirsaLaunchRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var bundleID: String
    var date: Date
    var source: MirsaLaunchSource
}

struct MirsaAppTelemetry: Codable, Equatable {
    var launches: [MirsaLaunchRecord] = []
    var crashes: [MirsaCrashReport] = []
    var manualAssociations: [String: String] = [:]   // crash id -> bundleID chosen by owner
}

/// JSON file store, bounded, atomic writes. Integration contract (parent wires):
///   MirsaTelemetryStore.shared.recordLaunchAttempt(bundleID:) from the Swift call site that asks the container to start a guest,
///   only after the request is accepted (not on button tap). GuestLoader.m ~203 is the in-process point but needs no change.
///   MirsaTelemetryView(bundleID:) from ProjectView
final class MirsaTelemetryStore {
    static let maxLaunches = 300, maxCrashes = 100
    static let shared = MirsaTelemetryStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MirsaTelemetry.json"))
    private let url: URL
    private let lock = NSLock()
    private var data: MirsaAppTelemetry

    init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), d.count < 8 * 1024 * 1024, let t = try? JSONDecoder().decode(MirsaAppTelemetry.self, from: d) { data = t } else { data = MirsaAppTelemetry() }
    }
    func recordLaunchAttempt(bundleID: String, source: MirsaLaunchSource = .containerAttempt, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        data.launches.append(MirsaLaunchRecord(bundleID: String(bundleID.prefix(256)), date: at, source: source))
        if data.launches.count > Self.maxLaunches { data.launches.removeFirst(data.launches.count - Self.maxLaunches) }
        save()
    }
    @discardableResult
    func importCrash(_ file: Data, provenance: MirsaCrashProvenance = .userImport) throws -> MirsaCrashReport {
        var r = try MirsaCrashParser.parse(file)
        r.provenance = provenance; r.importedManually = provenance == .userImport
        lock.lock(); defer { lock.unlock() }
        data.crashes.removeAll { $0.id == r.id }
        data.crashes.append(r)
        if data.crashes.count > Self.maxCrashes { data.crashes.removeFirst(data.crashes.count - Self.maxCrashes) }
        save(); return r
    }
    func associate(crashID: String, bundleID: String) {
        lock.lock(); defer { lock.unlock() }
        data.manualAssociations[crashID] = bundleID; save()
    }
    func launches(for bundleID: String) -> [MirsaLaunchRecord] {
        lock.lock(); defer { lock.unlock() }
        return data.launches.filter { $0.bundleID == bundleID }.sorted { $0.date > $1.date }
    }
    func crashes(for bundleID: String) -> [MirsaCrashReport] {
        lock.lock(); defer { lock.unlock() }
        return data.crashes.filter { ($0.bundleID ?? data.manualAssociations[$0.id]) == bundleID || data.manualAssociations[$0.id] == bundleID }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
    func unassociatedCrashes() -> [MirsaCrashReport] {
        lock.lock(); defer { lock.unlock() }
        return data.crashes.filter { $0.bundleID == nil && data.manualAssociations[$0.id] == nil }
    }
    func clear(bundleID: String) {
        lock.lock(); defer { lock.unlock() }
        data.launches.removeAll { $0.bundleID == bundleID }
        let ids = data.crashes.filter { ($0.bundleID ?? data.manualAssociations[$0.id]) == bundleID }.map(\.id)
        data.crashes.removeAll { ids.contains($0.id) }
        save()
    }
    private func save() {
        guard let d = try? JSONEncoder().encode(data) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
