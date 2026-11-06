import XCTest
import SwiftUI
@testable import Mirsa

private struct MockTransport: ScreenshotTransport {
    var responses: [String: Data] = [:]
    var counter: Counter = Counter()
    final class Counter: @unchecked Sendable { var n = 0 }
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        counter.n += 1
        guard let d = responses[url.absoluteString] else { throw ScreenshotFailure(message: "404") }
        guard d.count <= maxBytes else { throw ScreenshotFailure(message: "big") }
        return d
    }
}

final class AppScreenshotsTests: XCTestCase {
    private func png(_ w: Int, _ h: Int, _ color: UIColor = .systemTeal) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).pngData { c in
            color.setFill(); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
    private func tmpCache(ttl: TimeInterval = 3600, limit: Int = 1 << 20) -> ScreenshotCache {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return ScreenshotCache(directory: d, ttl: ttl, diskLimit: limit)
    }
    private let base = URL(string: "https://repo.example.org/source.json")!

    func testV1AndV2Schemas() {
        let v1 = ScreenshotPolicy.sourceScreenshots(["screenshotURLs": ["https://cdn.site.org/a.png", "/rel/b.png"]], base: URL(string: "https://repo.site.org/s.json"))
        XCTAssertEqual(v1.map(\.absoluteString), ["https://cdn.site.org/a.png", "https://repo.site.org/rel/b.png"])
        let v2 = ScreenshotPolicy.sourceScreenshots(["screenshots": [["imageURL": "https://cdn.site.org/c.png", "width": 1], "https://cdn.site.org/d.png"]], base: nil)
        XCTAssertEqual(v2.count, 2)
        let split = ScreenshotPolicy.sourceScreenshots(["screenshots": ["iphone": [["imageURL": "https://cdn.site.org/p.png"]], "ipad": ["https://cdn.site.org/i.png"]]], base: nil)
        XCTAssertEqual(split.map(\.lastPathComponent), ["p.png"])
        XCTAssertTrue(ScreenshotPolicy.sourceScreenshots([:], base: nil).isEmpty)
    }

    func testInvalidURLsRejected() {
        let bad = ["http://cdn.site.org/a.png", "https://user:pw@cdn.site.org/a.png", "https://127.0.0.1/a.png", "https://localhost/a.png",
                   "https://10.0.0.5/a.png", "https://cdn.site.org:8443/a.png", "https://printer.local/a.png", "file:///etc/passwd", "javascript:alert(1)",
                   "https://[::1]/a.png", "https://cdn.site.org/a.png#frag", "", "https://2130706433/a.png"]
        XCTAssertTrue(ScreenshotPolicy.sourceScreenshots(["screenshotURLs": bad], base: nil).isEmpty)
        XCTAssertTrue(ScreenshotPolicy.sourceScreenshots(["screenshotURLs": [1, NSNull(), ["x": 1]]], base: nil).isEmpty)
    }

    func testCountBoundedAndDeduped() {
        let many = (0..<40).map { "https://cdn.site.org/\($0 % 25).png" }
        XCTAssertEqual(ScreenshotPolicy.sourceScreenshots(["screenshotURLs": many], base: nil).count, ScreenshotPolicy.maxCount)
    }

    func testAppStoreExactBundleOnly() {
        let json = """
        {"results":[{"bundleId":"com.other.app","screenshotUrls":["https://is1-ssl.mzstatic.com/x/other.png"]},
        {"bundleId":"com.Exact.App","screenshotUrls":["https://is1-ssl.mzstatic.com/x/1.png","https://evil.example.org/2.png","http://is1-ssl.mzstatic.com/3.png"]}]}
        """.data(using: .utf8)!
        XCTAssertEqual(ScreenshotPolicy.appStoreScreenshots(json: json, bundleID: "com.exact.app").map(\.lastPathComponent), ["1.png"])
        XCTAssertTrue(ScreenshotPolicy.appStoreScreenshots(json: json, bundleID: "com.none.app").isEmpty)
        XCTAssertTrue(ScreenshotPolicy.appStoreScreenshots(json: Data("garbage".utf8), bundleID: "com.exact.app").isEmpty)
        XCTAssertTrue(ScreenshotPolicy.appStoreScreenshots(json: Data(count: ScreenshotPolicy.maxJSONBytes + 1), bundleID: "com.exact.app").isEmpty)
    }

    func testLookupURLValidation() {
        XCTAssertNotNil(ScreenshotPolicy.lookupURL(bundleID: "com.example.app"))
        XCTAssertEqual(ScreenshotPolicy.lookupURL(bundleID: "com.example.app")?.host, "itunes.apple.com")
        for b in ["Instagram", "com.x&limit=9", "com.x/..", "", "a b.c", "com.x\n.y"] { XCTAssertNil(ScreenshotPolicy.lookupURL(bundleID: b), b) }
    }

    func testDecodeBounds() {
        XCTAssertNotNil(ScreenshotPolicy.decode(png(200, 400)))
        XCTAssertNil(ScreenshotPolicy.decode(Data("not an image".utf8)))
        XCTAssertNil(ScreenshotPolicy.decode(Data()))
        XCTAssertNil(ScreenshotPolicy.decode(png(10_100, 2)))
        XCTAssertNil(ScreenshotPolicy.decode(Data(count: ScreenshotPolicy.maxImageBytes + 1)))
        let big = ScreenshotPolicy.decode(png(3000, 3000))
        XCTAssertLessThanOrEqual(max(big?.size.width ?? 9999, big?.size.height ?? 9999) * (big?.scale ?? 1), 1600)
    }

    func testLoaderCachesAndRejectsBadBytes() async throws {
        let ok = URL(string: "https://cdn.site.org/ok.png")!, bad = URL(string: "https://cdn.site.org/bad.png")!
        let transport = MockTransport(responses: [ok.absoluteString: png(100, 200), bad.absoluteString: Data("<html>".utf8)])
        let loader = ScreenshotLoader(transport: transport, cache: tmpCache())
        _ = try await loader.image(ok); _ = try await loader.image(ok)
        XCTAssertEqual(transport.counter.n, 1)
        do { _ = try await loader.image(bad); XCTFail() } catch { }
        do { _ = try await loader.image(URL(string: "https://cdn.site.org/missing.png")!); XCTFail() } catch { }
    }

    func testFallbackUsesExactBundle() async {
        let lookup = ScreenshotPolicy.lookupURL(bundleID: "com.exact.app")!
        let json = #"{"results":[{"bundleId":"com.exact.app","screenshotUrls":["https://is1-ssl.mzstatic.com/a.png"]}]}"#.data(using: .utf8)!
        let loader = ScreenshotLoader(transport: MockTransport(responses: [lookup.absoluteString: json]), cache: tmpCache())
        let urls = await loader.appStoreFallback(bundleID: "com.exact.app")
        XCTAssertEqual(urls.count, 1)
        let none = await loader.appStoreFallback(bundleID: "Not A Bundle")
        XCTAssertTrue(none.isEmpty)
    }

    func testCacheTTLAndEviction() throws {
        let c = tmpCache(ttl: 100, limit: 3000)
        let urls = (0..<4).map { URL(string: "https://cdn.site.org/\($0).png")! }
        for (i, u) in urls.enumerated() {
            let data = Data(count: 1200)
            c.store(data, image: UIImage(), for: u)
            let f = c.directory.appendingPathComponent(c.key(u) + ".img")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 10))], ofItemAtPath: f.path)
        }
        c.evict()
        let left = try FileManager.default.contentsOfDirectory(atPath: c.directory.path).filter { $0.hasSuffix(".img") }
        XCTAssertLessThanOrEqual(left.count * 1200, 3000)
        XCTAssertFalse(left.contains(c.key(urls[0]) + ".img"))
        c.evict(now: Date(timeIntervalSinceNow: 1000))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: c.directory.path).filter { $0.hasSuffix(".img") }.isEmpty)
    }

    func testCancellationPropagates() async {
        struct Slow: ScreenshotTransport { func fetch(_ url: URL, maxBytes: Int) async throws -> Data { try await Task.sleep(nanoseconds: 5_000_000_000); return Data() } }
        let loader = ScreenshotLoader(transport: Slow(), cache: tmpCache())
        let t = Task { try await loader.image(URL(string: "https://cdn.site.org/s.png")!) }
        t.cancel()
        do { _ = try await t.value; XCTFail() } catch { }
    }

    @MainActor
    func testGalleryScreenshots() async throws {
        let colors: [UIColor] = [.systemIndigo, .systemOrange, .systemPink, .systemGreen]
        let urls = (0..<4).map { URL(string: "https://gallery.test-cdn.org/\($0).png")! }
        for (i, u) in urls.enumerated() {
            let data = png(390, 780, colors[i]); ScreenshotCache.shared.store(data, image: ScreenshotPolicy.decode(data)!, for: u)
        }
        let app = RepoApp(name: "Demo", bundleID: "com.demo.app", developer: "Dev", subtitle: "", description: "Demo app with screenshots.", version: "1.0",
                          iconURL: nil, downloadURL: URL(string: "https://cdn.site.org/a.ipa")!, size: nil, date: nil, screenshots: urls)
        func shot(_ view: some View, _ name: String) async {
            let host = UIHostingController(rootView: view.environment(\.colorScheme, .dark))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
            window.frame = UIScreen.main.bounds
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let img = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            withExtendedLifetime(window) {}
            let a = XCTAttachment(image: img); a.name = name; a.lifetime = .keepAlways; add(a)
        }
        await shot(ZStack { Color.black.ignoresSafeArea(); AppScreenshotGallery(app: app).padding() }, "gallery-thumbnails")
        await shot(FullscreenScreenshots(urls: urls, start: 1), "gallery-fullscreen")
        let missing = RepoApp(name: "Demo", bundleID: "com.demo.app", developer: "", subtitle: "", description: "", version: "", iconURL: nil,
                              downloadURL: URL(string: "https://cdn.site.org/a.ipa")!, size: nil, date: nil, screenshots: [URL(string: "https://gallery.test-cdn.org/missing.png")!])
        await shot(ZStack { Color.black.ignoresSafeArea(); AppScreenshotGallery(app: missing).padding() }, "gallery-error-placeholder")
    }
}
