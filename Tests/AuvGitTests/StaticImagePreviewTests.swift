import XCTest
import AppKit
@testable import AuvGit

@MainActor
final class StaticImagePreviewTests: XCTestCase {
    func testPNGPreviewAndSourceDimensions() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let first = try XCTUnwrap(StaticImagePreview.image(data))
        XCTAssertTrue(StaticImagePreview.image(data) === first, "Repeated body updates must reuse the decoded image")
        let replacement = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let changed = try XCTUnwrap(replacement.representation(using: .png, properties: [:]))
        XCTAssertNotEqual(changed, data)
        XCTAssertFalse(StaticImagePreview.image(changed) === first, "Changed bytes must not reuse an old preview")
        XCTAssertEqual(StaticImagePreview.dimensions(data)?.0, 3)
        XCTAssertEqual(StaticImagePreview.dimensions(data)?.1, 2)
    }
    func testCorruptedImageAndActiveDocumentAreRejected() {
        XCTAssertNil(StaticImagePreview.image(Data([137, 80, 78, 71, 0])))
        XCTAssertNil(StaticImagePreview.image(Data("<html><script>alert(1)</script></html>".utf8)))
        XCTAssertNil(StaticImagePreview.image(Data("<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>".utf8)))
    }
}

@MainActor
final class SafeStaticDocumentTests: XCTestCase {
    func testSVGRejectsActiveExternalAndEntityContent() {
        let safe = Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'><rect width='20' height='10' fill='red'/></svg>".utf8)
        XCTAssertTrue(SafeStaticDocument.isSafeSVG(safe))
        for text in [
            "<svg><script>alert(1)</script></svg>",
            "<svg onload='alert(1)'/>",
            "<svg><use href='https://example.invalid/external.svg'/></svg>",
            "<svg xmlns:x='http://www.w3.org/1999/xlink'><use x:href='file:///etc/passwd'/></svg>",
            "<svg><foreignObject><html/></foreignObject></svg>",
            "<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg>&x;</svg>",
            "<svg><rect style='fill:url(https://example.invalid/image)'/></svg>",
            "<svg><rect style='fill:u\\72l(https://example.invalid/image)'/></svg>"
        ] { XCTAssertFalse(SafeStaticDocument.isSafeSVG(Data(text.utf8)), text) }
    }
    func testPDFStaticFirstPageAndPageCount() throws {
        let output = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 40, height: 30)
        let consumer = try XCTUnwrap(CGDataConsumer(data: output as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.setFillColor(NSColor.red.cgColor); context.fill(bounds); context.endPDFPage() }
        context.closePDF()
        let data = output as Data
        XCTAssertEqual(SafeStaticDocument.pdfPageCount(data), 2)
        let first = try XCTUnwrap(StaticImagePreview.image(data))
        XCTAssertTrue(StaticImagePreview.image(data) === first, "PDF pages must not be rendered again for each opacity or selection update")
    }
}
