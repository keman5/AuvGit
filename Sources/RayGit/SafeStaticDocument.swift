import AppKit
import Foundation
import CoreGraphics

/// Only static PDF pages and a restricted, local-reference SVG subset reach native rendering.
enum SafeStaticDocument {
    static func pdfPageCount(_ data: Data) -> Int? {
        guard data.starts(with: Data("%PDF-".utf8)), let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), !document.isEncrypted else { return nil }
        return document.numberOfPages > 0 ? document.numberOfPages : nil
    }
    static func image(_ data: Data) -> NSImage? {
        if let _ = pdfPageCount(data), let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) {
            let bounds = page.getBoxRect(.cropBox)
            guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return nil }
            let scale = min(1, 2048 / max(bounds.width, bounds.height))
            let width = max(1, Int(ceil(bounds.width * scale))), height = max(1, Int(ceil(bounds.height * scale)))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let result = context.makeImage() else { return nil }
            return NSImage(cgImage: result, size: NSSize(width: width, height: height))
        }
        guard isSafeSVG(data), let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              image.size.width.isFinite, image.size.height.isFinite else { return nil }
        // SVG input remains untouched; the visible native raster is bounded.
        let size = image.size
        let scale = min(1, 2048 / max(size.width, size.height))
        let preview = NSImage(size: NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale)))
        preview.lockFocus(); defer { preview.unlockFocus() }
        image.draw(in: NSRect(origin: .zero, size: preview.size), from: .zero, operation: .sourceOver, fraction: 1)
        return preview
    }
    static func isSafeSVG(_ data: Data) -> Bool {
        guard data.count <= 2 * 1024 * 1024, let value = String(data: data, encoding: .utf8) else { return false }
        let lower = value.lowercased()
        guard !lower.contains("<!doctype"), !lower.contains("<!entity"), !lower.contains("xml-stylesheet") else { return false }
        let delegate = SVGValidator(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        return parser.parse() && delegate.valid && delegate.rootSeen
    }
    private final class SVGValidator: NSObject, XMLParserDelegate {
        var valid = true, rootSeen = false, depth = 0, nodes = 0
        private let tags: Set<String> = ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "defs", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "use", "symbol", "title", "desc"]
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            depth += 1; nodes += 1
            if depth == 1 { rootSeen = elementName == "svg" }
            guard rootSeen, tags.contains(elementName), depth <= 128, nodes <= 100_000 else { valid = false; parser.abortParsing(); return }
            for (name, value) in attributeDict {
                let key = name.lowercased(), content = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if key.hasPrefix("on") || ((key == "href" || key.hasSuffix(":href")) && !content.hasPrefix("#")) || key == "xml:base" || key.hasSuffix(":base") {
                    valid = false; parser.abortParsing(); return
                }
                if content.contains("\\") || content.contains("/*") || (!key.hasPrefix("xmlns") && content.contains("://")) {
                    valid = false; parser.abortParsing(); return
                }
                if content.contains("url(") {
                    let safe = content.replacingOccurrences(of: #"url\(\s*['\"]?#[a-z0-9_.:-]+['\"]?\s*\)"#, with: "", options: .regularExpression)
                    if safe.contains("url(") { valid = false; parser.abortParsing(); return }
                }
                if content.contains("javascript:") || content.contains("data:") || content.contains("expression(") || content.contains("@import") {
                    valid = false; parser.abortParsing(); return
                }
            }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { valid = false; parser.abortParsing() }
    }
}
