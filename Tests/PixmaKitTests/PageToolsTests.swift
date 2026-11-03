import XCTest
import CoreImage
import CoreText
@testable import ScanProcessing

/// Synthetic scans for page detection, straightening, flattening and the page checks.
final class PageToolsTests: XCTestCase {
    let processor = ImageProcessor()
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A canvas with a top-left origin (y grows downward), filled with `background` gray.
    func canvas(_ w: Int, _ h: Int, background: CGFloat, draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: background, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx)
        return ctx.makeImage()!
    }

    /// Draws lines of text (top-left coordinates) in the current context.
    func text(_ ctx: CGContext, _ lines: [String], at origin: CGPoint, size: CGFloat, spacing: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        for (n, s) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorFromContextAttributeName as String): true,
            ]))
            ctx.saveGState()
            ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
            // Undo the flip locally so glyphs aren't mirrored.
            ctx.translateBy(x: origin.x, y: origin.y + CGFloat(n) * spacing)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    static let prose = Array(repeating: "The quick brown fox jumps over the lazy dog while scanners hum quietly", count: 14)

    func textPage(width: Int = 1200, height: Int = 900, margin: CGFloat = 60) -> CGImage {
        canvas(width, height, background: 0.97) { ctx in
            let lines = margin < 60 ? Self.prose.map { $0 + " and " + $0 } : Self.prose
            text(ctx, lines, at: CGPoint(x: margin, y: 80), size: 26, spacing: 52)
        }
    }

    func rendered(_ image: CIImage) -> CGImage { CIContext().createCGImage(image, from: image.extent.integral)! }

    // MARK: - Straightening

    func testTextSkewIsMeasuredAndRemoved() throws {
        let page = CIImage(cgImage: textPage())
        let e = page.extent
        // Turn the content 3° clockwise on screen (negative in Core Image's y-up space), on white.
        let turned = page.transformed(by: CGAffineTransform(translationX: e.midX, y: e.midY).rotated(by: -3 * .pi / 180)
                                        .translatedBy(x: -e.midX, y: -e.midY))
            .composited(over: CIImage(color: .white).cropped(to: e)).cropped(to: e)
        let skew = try XCTUnwrap(processor.textSkew(turned, dpi: 150))
        XCTAssertEqual(skew, 3, accuracy: 0.15)

        var o = ProcessingOptions()
        o.autoCrop = .straighten
        let out = try processor.process(turned, dpi: 150, options: o)[0]
        let after = processor.textSkew(CIImage(cgImage: out.image), dpi: 150) ?? 0
        XCTAssertEqual(after, 0, accuracy: 0.15)
    }

    func testNoSkewReportedForPlainPhoto() {
        let gradient = CIImage(cgImage: canvas(600, 400, background: 0.5) { ctx in
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 100, y: 80, width: 300, height: 220))
        })
        XCTAssertNil(processor.textSkew(gradient, dpi: 150))
    }

    // MARK: - Finding pages

    /// The MX920 glass at 75 dpi with a lid-coloured background.
    func glass(_ draw: (CGContext) -> Void) -> CIImage {
        CIImage(cgImage: canvas(638, 877, background: 236.0 / 255, draw: draw))
    }

    func assertQuad(_ q: Quad?, near corners: [CGPoint], inches tolerance: CGFloat = 0.12,
                    file: StaticString = #filePath, line: UInt = #line) {
        guard let q else { return XCTFail("nothing detected", file: file, line: line) }
        for (p, expected) in zip(q.points, corners) {
            let dx = (p.x * 638 - expected.x) / 75, dy = (p.y * 877 - expected.y) / 75
            XCTAssertLessThan(hypot(dx, dy), tolerance, "corner \(p) vs \(expected)", file: file, line: line)
        }
    }

    func testDetectsTiltedColouredPage() {
        let corners = [CGPoint(x: 100, y: 80), CGPoint(x: 548, y: 111), CGPoint(x: 510, y: 708), CGPoint(x: 62, y: 677)]
        let image = glass { ctx in
            ctx.setFillColor(CGColor(red: 0.95, green: 0.78, blue: 0.55, alpha: 1))
            ctx.addLines(between: corners)
            ctx.fillPath()
        }
        assertQuad(processor.detectDocument(image, dpi: 75), near: corners)
    }

    func testDetectsWhitePageByItsEdgeShadow() {
        let rect = CGRect(x: 120, y: 90, width: 400, height: 520)
        let image = glass { ctx in
            ctx.setFillColor(CGColor(gray: 0.985, alpha: 1))
            ctx.fill(rect)
            ctx.setStrokeColor(CGColor(gray: 0.72, alpha: 1))
            ctx.setLineWidth(1.5)
            ctx.stroke(rect)
            text(ctx, ["Invoice 2041", "Total due 12.50"], at: CGPoint(x: 160, y: 160), size: 14, spacing: 24)
        }
        assertQuad(processor.detectDocument(image, dpi: 75), near: [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ])
    }

    func testInvisibleWhitePageSnapsToLetterAtTheCorner() {
        // Page and lid are the same white: only the print shows. It sits against the origin corner.
        let image = glass { ctx in
            text(ctx, Self.prose.prefix(20).map { String($0.prefix(48)) }, at: CGPoint(x: 70, y: 70), size: 13, spacing: 34)
        }
        assertQuad(processor.detectDocument(image, dpi: 75), near: [
            CGPoint(x: 0, y: 0), CGPoint(x: 637.5, y: 0), CGPoint(x: 637.5, y: 825), CGPoint(x: 0, y: 825),
        ], inches: 0.05)
    }

    func testEmptyGlassFindsNothing() {
        XCTAssertNil(processor.detectDocument(glass { _ in }, dpi: 75))
        XCTAssertTrue(processor.detectItems(glass { _ in }, dpi: 75).isEmpty)
    }

    func testDetectsSeparatePhotosInReadingOrder() {
        let image = glass { ctx in
            ctx.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 360, y: 60, width: 220, height: 150))     // top right
            ctx.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 50, y: 70, width: 200, height: 280))      // top left
            ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 150, y: 500, width: 300, height: 200))    // bottom
        }
        let items = processor.detectItems(image, dpi: 75)
        XCTAssertEqual(items.count, 3)
        guard items.count == 3 else { return }
        XCTAssertLessThan(items[0].boundingBox.minX, 0.2)   // top left first
        XCTAssertGreaterThan(items[1].boundingBox.minX, 0.5)
        XCTAssertGreaterThan(items[2].boundingBox.minY, 0.5)
    }

    // MARK: - Curved pages

    /// Row offset between a narrow strip at `x` and the middle strip, by cross-correlating dark-pixel profiles.
    func lineOffset(_ image: CGImage, strip x0: Int) -> Int {
        let r = processor.raster(CIImage(cgImage: image), maxSide: CGFloat(max(image.width, image.height)))!
        func profile(_ x: Int) -> [Double] {
            (0..<r.height).map { y in Double((x..<(x + 40)).filter { r[$0, y] < 128 }.count) }
        }
        let a = profile(r.width / 2 - 20), b = profile(x0)
        return (-25...25).max { d1, d2 in
            func score(_ d: Int) -> Double { (30..<(r.height - 30)).reduce(0) { $0 + a[$1] * b[$1 + d] } }
            return score(d1) < score(d2)
        }!
    }

    func testFlattenCurvedPageStraightensBentLines() throws {
        let flat = textPage(margin: 10)   // text across the whole width, like a book page
        // Bend the lines down toward both edges, like a page curling away from the spine.
        let w = flat.width, h = flat.height
        var src = [UInt8](repeating: 0, count: w * h * 4), dst = src
        let ctx = CGContext(data: &src, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(flat, in: CGRect(x: 0, y: 0, width: w, height: h))
        for y in 0..<h {
            for x in 0..<w {
                let u = (Double(x) - Double(w) / 2) / (Double(w) / 2)
                let sy = min(h - 1, max(0, y - Int(14 * u * u)))
                for c in 0..<4 { dst[(y * w + x) * 4 + c] = src[(sy * w + x) * 4 + c] }
            }
        }
        let bentCtx = CGContext(data: &dst, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bent = bentCtx.makeImage()!
        XCTAssertGreaterThanOrEqual(abs(lineOffset(bent, strip: 60)), 10)
        XCTAssertGreaterThanOrEqual(abs(lineOffset(bent, strip: w - 100)), 10)

        var o = ProcessingOptions()
        o.flattenCurvedPages = true
        let out = try processor.process(CIImage(cgImage: bent), dpi: 150, options: o)[0]
        XCTAssertLessThanOrEqual(abs(lineOffset(out.image, strip: 60)), 2)
        XCTAssertLessThanOrEqual(abs(lineOffset(out.image, strip: w - 100)), 2)
    }

    func testFlattenLeavesStraightPageAlone() throws {
        var o = ProcessingOptions()
        o.flattenCurvedPages = true
        let page = textPage()
        let out = try processor.process(CIImage(cgImage: page), dpi: 150, options: o)[0]
        XCTAssertEqual(lineOffset(out.image, strip: 60), 0)
    }

    // MARK: - Page checks

    func testBlankPagesAreSkipped() throws {
        var o = ProcessingOptions()
        o.skipBlankPages = true
        let blank = canvas(850, 1100, background: 0.95) { ctx in
            ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 400, y: 500, width: 2, height: 2))     // a speck of dust
            ctx.fill(CGRect(x: 0, y: 0, width: 850, height: 20))      // edge shadow
        }
        XCTAssertTrue(try processor.process(CIImage(cgImage: blank), dpi: 100, options: o).isEmpty)
        let oneLine = canvas(850, 1100, background: 0.95) { ctx in
            text(ctx, ["Signed and dated"], at: CGPoint(x: 100, y: 600), size: 16, spacing: 20)
        }
        XCTAssertEqual(try processor.process(CIImage(cgImage: oneLine), dpi: 100, options: o).count, 1)
    }

    func testAutomaticColourPicksGrayForBlackPrint() throws {
        var o = ProcessingOptions()
        o.outputColor = .auto
        let print = try processor.process(CIImage(cgImage: textPage()), dpi: 150, options: o)[0]
        XCTAssertEqual(print.image.colorSpace?.model, .monochrome)
        let chart = canvas(600, 400, background: 1) { ctx in
            ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 50, y: 50, width: 200, height: 100))
        }
        let colour = try processor.process(CIImage(cgImage: chart), dpi: 150, options: o)[0]
        XCTAssertEqual(colour.image.colorSpace?.model, .rgb)
    }

    func testAutoRotateTurnsSidewaysTextUpright() throws {
        let page = CIImage(cgImage: textPage())
        // Lying on its side: rotated 90° counter-clockwise, so it needs 90° clockwise.
        let sideways = processor.rotate(page, degrees: 270)
        XCTAssertEqual(processor.uprightRotation(sideways), 90)
        XCTAssertEqual(processor.uprightRotation(processor.rotate(page, degrees: 180)), 180)
        XCTAssertEqual(processor.uprightRotation(page), 0)

        var o = ProcessingOptions()
        o.autoRotate = true
        let out = try processor.process(sideways, dpi: 150, options: o)[0]
        XCTAssertEqual(out.image.width, 1200)
        XCTAssertEqual(processor.uprightRotation(CIImage(cgImage: out.image)), 0)
    }

    func testRotationCheckCopesWithSolidBlocks() {
        // A text "line" whose densest rows reach its last row once crashed the ascender count.
        let bars = canvas(400, 300, background: 1) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 40, width: 360, height: 30))
            ctx.fill(CGRect(x: 20, y: 120, width: 360, height: 30))
        }
        XCTAssertEqual(processor.ascenderRatio(CIImage(cgImage: bars)), 1, accuracy: 0.01)
    }

    func testSplitsSpreadAtTheSpine() throws {
        let spread = canvas(1600, 1000, background: 0.96) { ctx in
            // Spine shadow a little right of centre.
            for i in 0..<40 {
                ctx.setFillColor(CGColor(gray: 0.55 + 0.01 * CGFloat(abs(i - 20)), alpha: 1))
                ctx.fill(CGRect(x: 860 + i, y: 0, width: 1, height: 1000))
            }
        }
        var o = ProcessingOptions()
        o.splitFacingPages = true
        let pages = try processor.process(CIImage(cgImage: spread), dpi: 150, options: o)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].image.width, 880, accuracy: 6)
        XCTAssertEqual(pages[0].image.width + pages[1].image.width, 1600)

        let portrait = try processor.process(CIImage(cgImage: textPage(width: 800, height: 1100)), dpi: 150, options: o)
        XCTAssertEqual(portrait.count, 1)
    }

    // MARK: - Settings

    func testOlderSavedOptionsStillDecode() throws {
        let json = #"{"autoAdjust":true,"autoCrop":"document","outputColor":"gray","reduceDust":"low"}"#
        let o = try JSONDecoder().decode(ProcessingOptions.self, from: Data(json.utf8))
        XCTAssertTrue(o.autoAdjust)
        XCTAssertEqual(o.autoCrop, .document)
        XCTAssertEqual(o.reduceDust, .low)
        XCTAssertFalse(o.flattenCurvedPages)
        XCTAssertNil(o.cropQuad)
    }
}
