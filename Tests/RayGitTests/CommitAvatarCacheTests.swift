import XCTest
import AppKit
@testable import RayGit

@MainActor
final class CommitAvatarCacheTests: XCTestCase {
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    func testConcurrentRowsShareRequestAndReuseDecodedImage() async throws {
        let data = try png(); var requests = 0
        let cache = CommitAvatarCache(loader: { _ in requests += 1; await Task.yield(); return data })
        let url = try XCTUnwrap(URL(string: "https://example.invalid/avatar"))
        async let first = cache.image(for: url)
        async let second = cache.image(for: url)
        let images = await (first, second)
        XCTAssertNotNil(images.0); XCTAssertTrue(images.0 === images.1)
        let reused = await cache.image(for: url)
        XCTAssertTrue(reused === images.0); XCTAssertEqual(requests, 1)
        XCTAssertTrue(cache.cachedImage(for: url) === images.0)
    }
    func testBoundedLRUAndMissingAvatarRetryAfterExpiry() async throws {
        var requests = 0, clock = Date(timeIntervalSince1970: 100)
        let cache = CommitAvatarCache(capacity: 2, now: { clock }, loader: { _ in requests += 1; return nil })
        let urls = (0...2).map { URL(string: "https://example.invalid/\($0)")! }
        _ = await cache.image(for: urls[0]); _ = await cache.image(for: urls[1])
        _ = await cache.image(for: urls[0]); _ = await cache.image(for: urls[2])
        XCTAssertEqual(requests, 3); XCTAssertEqual(cache.cachedCount, 2)
        _ = await cache.image(for: urls[1])
        XCTAssertEqual(requests, 4); XCTAssertEqual(cache.cachedCount, 2)
        _ = await cache.image(for: urls[1]); XCTAssertEqual(requests, 4)
        clock = clock.addingTimeInterval(301)
        _ = await cache.image(for: urls[1]); XCTAssertEqual(requests, 5)
    }
    func testOversizedResponseIsNotDecoded() async throws {
        let cache = CommitAvatarCache(loader: { _ in Data(repeating: 0, count: 1_048_577) })
        let image = await cache.image(for: URL(string: "https://example.invalid/large")!)
        XCTAssertNil(image)
    }
}
