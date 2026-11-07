import Foundation
import CryptoKit
import ImageIO
import UIKit
#if canImport(AirliftFFI)
import AirliftFFI
#endif

// MARK: - URL parsing / policy (pure, testable)

enum ScreenshotPolicy {
    static let maxCount = 10
    static let maxImageBytes = 8 * 1024 * 1024
    static let maxJSONBytes = 512 * 1024
    static let maxPixelSide = 10_000
    static let maxPixels = 50_000_000
    static let requestSeconds: UInt64 = 20

    /// Resolves relative to the source URL and applies the shared https/public-host policy.
    static func safeURL(_ raw: Any?, base: URL?) -> URL? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count <= DiscoveryURLPolicy.maxURLLength,
              let u = URL(string: s, relativeTo: base)?.absoluteURL, u.fragment == nil,
              DiscoveryURLPolicy.check(u) == nil else { return nil }
        return u
    }

    /// Understands AltStore v1 (screenshotURLs), v2 (screenshots: [String] | [{imageURL}] | {iphone:[..], ipad:[..]}).
    static func sourceScreenshots(_ app: [String: Any], latest: [String: Any]? = nil, base: URL?) -> [URL] {
        func flatten(_ v: Any?) -> [Any] {
            if let a = v as? [Any] { return a }
            if let d = v as? [String: Any] {
                let phone = flatten(d["iphone"] ?? d["iPhone"]); if !phone.isEmpty { return phone }
                return flatten(d["ipad"] ?? d["iPad"])
            }
            return []
        }
        var raw = flatten(app["screenshotURLs"])
        if raw.isEmpty { raw = flatten(app["screenshots"]) }
        if raw.isEmpty { raw = flatten(app["screenshotUrls"]) }
        var seen = Set<String>(), out: [URL] = []
        for item in raw {
            let candidate: Any? = (item as? [String: Any]).flatMap { $0["imageURL"] ?? $0["imageUrl"] ?? $0["url"] } ?? item
            guard let u = safeURL(candidate, base: base), seen.insert(u.absoluteString).inserted else { continue }
            out.append(u)
            if out.count == maxCount { break }
        }
        return out
    }

    static func validBundleID(_ id: String) -> Bool {
        id.count <= 155 && id.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    static func lookupURL(bundleID: String) -> URL? {
        guard validBundleID(bundleID) else { return nil }
        var c = URLComponents(); c.scheme = "https"; c.host = "itunes.apple.com"; c.path = "/lookup"
        c.queryItems = [.init(name: "bundleId", value: bundleID), .init(name: "entity", value: "software"), .init(name: "limit", value: "5")]
        return c.url
    }

    /// Exact bundle-ID match only; images must live on Apple's mzstatic CDN. Nothing is invented.
    static func appStoreScreenshots(json: Data, bundleID: String) -> [URL] {
        guard json.count <= maxJSONBytes,
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        guard let hit = results.first(where: { ($0["bundleId"] as? String)?.lowercased() == bundleID.lowercased() }) else { return [] }
        var raw = (hit["screenshotUrls"] as? [String]) ?? []
        if raw.isEmpty { raw = (hit["ipadScreenshotUrls"] as? [String]) ?? [] }
        var seen = Set<String>(), out: [URL] = []
        for s in raw {
            guard let u = safeURL(s, base: nil), let h = u.host?.lowercased(), h == "mzstatic.com" || h.hasSuffix(".mzstatic.com"),
                  seen.insert(u.absoluteString).inserted else { continue }
            out.append(u)
            if out.count == maxCount { break }
        }
        return out
    }

    /// Bounded decode: validates header dimensions BEFORE decoding, returns a downsampled bitmap.
    static func decode(_ data: Data, maxPixel: Int = 1600) -> UIImage? {
        guard data.count > 0, data.count <= maxImageBytes else { return nil }
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts), CGImageSourceGetCount(src) >= 1,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= maxPixelSide, h <= maxPixelSide, w * h <= maxPixels else { return nil }
        let thumb: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumb as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Transport (pinned Rust transport, mockable)

protocol ScreenshotTransport: Sendable {
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data
}

struct ScreenshotFailure: Error, Equatable { let message: String }

struct PinnedScreenshotTransport: ScreenshotTransport {
    #if canImport(AirliftFFI)
    private final class Token: @unchecked Sendable {
        let p = al_discovery_cancel_new()
        deinit { al_discovery_cancel_free(p) }
    }
    #endif
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        if DiscoveryURLPolicy.check(url) != nil { throw ScreenshotFailure(message: "unsafe url") }
        #if canImport(AirliftFFI)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString).bin")
        let token = Token(), source = url.absoluteString
        defer { try? FileManager.default.removeItem(at: dest) }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    let err = source.withCString { s in dest.path.withCString { d in
                        al_discovery_download(s, d, UInt64(maxBytes), ScreenshotPolicy.requestSeconds, token.p) } }
                    if let err { let m = String(cString: err); al_string_free(err); c.resume(throwing: ScreenshotFailure(message: m)); return }
                    do {
                        let size = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
                        guard size > 0, size <= maxBytes else { throw ScreenshotFailure(message: "size") }
                        c.resume(returning: try Data(contentsOf: dest))
                    } catch { c.resume(throwing: error) }
                }
            }
        }, onCancel: { al_discovery_cancel(token.p) })
        #else
        throw ScreenshotFailure(message: "Pinned transport unavailable")
        #endif
    }
}

// MARK: - Cache (memory + disk, TTL + eviction)

final class ScreenshotCache: @unchecked Sendable {
    static let shared = ScreenshotCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MirsaScreenshots", isDirectory: true))
    let directory: URL, ttl: TimeInterval, diskLimit: Int
    private let memory = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    init(directory: URL, ttl: TimeInterval = 7 * 86_400, diskLimit: Int = 64 * 1024 * 1024, memoryLimit: Int = 48 * 1024 * 1024) {
        self.directory = directory; self.ttl = ttl; self.diskLimit = diskLimit
        memory.totalCostLimit = memoryLimit; memory.countLimit = 40
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func key(_ url: URL) -> String { SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func file(_ url: URL) -> URL { directory.appendingPathComponent(key(url) + ".img") }

    func image(for url: URL, now: Date = Date()) -> UIImage? {
        if let m = memory.object(forKey: key(url) as NSString) { return m }
        let f = file(url)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path), let m = attrs[.modificationDate] as? Date else { return nil }
        if now.timeIntervalSince(m) > ttl { try? FileManager.default.removeItem(at: f); return nil }
        guard let data = try? Data(contentsOf: f), let img = ScreenshotPolicy.decode(data) else { try? FileManager.default.removeItem(at: f); return nil }
        remember(img, for: url)
        return img
    }
    func remember(_ img: UIImage, for url: URL) {
        memory.setObject(img, forKey: key(url) as NSString, cost: Int(img.size.width * img.scale * img.size.height * img.scale * 4))
    }
    func store(_ data: Data, image: UIImage, for url: URL) {
        remember(image, for: url)
        lock.lock(); defer { lock.unlock() }
        try? data.write(to: file(url), options: .atomic)
        evict()
    }
    func evict(now: Date = Date()) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries: [(URL, Date, Int)] = []
        for f in files where f.pathExtension == "img" {
            let v = try? f.resourceValues(forKeys: Set(keys))
            let d = v?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(d) > ttl { try? FileManager.default.removeItem(at: f); continue }
            entries.append((f, d, v?.fileSize ?? 0))
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        for e in entries.sorted(by: { $0.1 < $1.1 }) where total > diskLimit {
            try? FileManager.default.removeItem(at: e.0); total -= e.2
        }
    }
    func clearMemory() { memory.removeAllObjects() }
}

// MARK: - Loader

actor ScreenshotLimiter {
    private var running = 0; private var waiters: [CheckedContinuation<Void, Never>] = []
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func acquire() async { if running < limit { running += 1 } else { await withCheckedContinuation { waiters.append($0) } } }
    func release() { if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() } }
}

final class ScreenshotLoader: @unchecked Sendable {
    static let shared = ScreenshotLoader()
    let transport: ScreenshotTransport, cache: ScreenshotCache
    private let limiter = ScreenshotLimiter(limit: 3)
    init(transport: ScreenshotTransport = PinnedScreenshotTransport(), cache: ScreenshotCache = .shared) { self.transport = transport; self.cache = cache }

    func image(_ url: URL) async throws -> UIImage {
        if let c = cache.image(for: url) { return c }
        await limiter.acquire()
        do {
            try Task.checkCancellation()
            let data = try await transport.fetch(url, maxBytes: ScreenshotPolicy.maxImageBytes)
            try Task.checkCancellation()
            guard let img = ScreenshotPolicy.decode(data) else { throw ScreenshotFailure(message: "invalid image") }
            cache.store(data, image: img, for: url)
            await limiter.release()
            return img
        } catch { await limiter.release(); throw error }
    }

    /// App Store fallback by exact bundle ID. Empty when nothing valid.
    func appStoreFallback(bundleID: String) async -> [URL] {
        guard let lookup = ScreenshotPolicy.lookupURL(bundleID: bundleID) else { return [] }
        guard let data = try? await transport.fetch(lookup, maxBytes: ScreenshotPolicy.maxJSONBytes) else { return [] }
        return ScreenshotPolicy.appStoreScreenshots(json: data, bundleID: bundleID)
    }
}
