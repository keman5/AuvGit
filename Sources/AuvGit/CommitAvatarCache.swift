import AppKit
import Foundation
import ImageIO

/// Shared decoded images survive row recycling; concurrent rows share one request.
@MainActor
final class CommitAvatarCache {
    static let shared = CommitAvatarCache()
    typealias Loader = (URL) async -> Data?
    private struct Entry {
        let image: NSImage?
        let expires: Date
        var access: UInt64
    }
    private let capacity: Int
    private let loader: Loader
    private let now: () -> Date
    private var entries: [URL: Entry] = [:]
    private var pending: [URL: Task<NSImage?, Never>] = [:]
    private var access: UInt64 = 0
    var cachedCount: Int { entries.count }

    init(capacity: Int = 256, now: @escaping () -> Date = Date.init, loader: Loader? = nil) {
        self.capacity = max(1, capacity); self.now = now
        self.loader = loader ?? { url in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= 1_048_576 else { return nil }
            return data
        }
    }
    func cachedImage(for url: URL) -> NSImage? {
        guard var entry = entries[url], entry.expires > now() else { return nil }
        access &+= 1; entry.access = access; entries[url] = entry
        return entry.image
    }
    func image(for url: URL) async -> NSImage? {
        access &+= 1
        if var entry = entries[url], entry.expires > now() {
            entry.access = access; entries[url] = entry; return entry.image
        }
        if let task = pending[url] { return await task.value }
        let loader = self.loader
        let task = Task { @MainActor () -> NSImage? in
            guard let data = await loader(url), data.count <= 1_048_576 else { return nil }
            let pixels = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 80,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            }.value
            guard let pixels else { return nil }
            return NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
        }
        pending[url] = task
        let image = await task.value
        pending[url] = nil; access &+= 1
        // Briefly retain failures too, so missing avatars never thrash on scroll.
        entries[url] = Entry(image: image, expires: image == nil ? now().addingTimeInterval(300) : .distantFuture, access: access)
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key { entries[oldest] = nil }
        return image
    }
}
