import XCTest
import CoreImage
import CoreText
import PDFKit
@testable import PixmaKit
@testable import ScanProcessing

final class ProcessingTests: XCTestCase {
    let processor = ImageProcessor()

    /// Builds an RGB page where `pixel(x, y)` returns the gray level.
    func page(width: Int, height: Int, dpi: Int = 300, _ pixel: (Int, Int) -> UInt8) throws -> ScannedPage {
        var data = Data(count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let v = pixel(x, y)
                let i = (y * width + x) * 3
                data[i] = v; data[i + 1] = v; data[i + 2] = v
            }
        }
        var r = ScanRequest()
        r.dpi = dpi
        r.width = width * 300 / dpi
        r.height = height * 300 / dpi
        let g = try PageGeometry.make(r, model: .mx920)
        return ScannedPage(geometry: g, pixels: data)
    }

    /// Reads back the gray value at (x, y), top-left origin, from a processed image.
    func gray(_ image: ProcessedImage, _ x: Int, _ y: Int) -> Int {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image.image, in: CGRect(x: -x, y: -(image.image.height - 1 - y),
                                         width: image.image.width, height: image.image.height))
        return (Int(px[0]) + Int(px[1]) + Int(px[2])) / 3
    }

    func testGutterCorrectionLiftsSpineShadowButKeepsText() throws {
        let p = try page(width: 300, height: 300) { x, y in
            if x % 37 == 5 && y % 11 < 3 { return 20 }                            // "text"
            return x < 60 ? UInt8(120 + (230 - 120) * x / 60) : 230                // shadow toward the left edge
        }
        var o = ProcessingOptions()
        o.gutterCorrection = true
        let out = try processor.process(p, options: o)[0]
        XCTAssertGreaterThan(gray(out, 10, 50), 200, "shadowed paper should be brightened")
        XCTAssertLessThan(gray(out, 5, 1), 90, "text in the shadow should stay dark")
        XCTAssertGreaterThan(gray(out, 200, 50), 220, "clean paper should be unchanged")
    }

    func testDustReductionRemovesSpecksButNotShapes() throws {
        let p = try page(width: 120, height: 120) { x, y in
            if (x, y) == (20, 20) || (x, y) == (90, 30) { return 0 }               // dust specks
            if (40..<70).contains(x) && (60..<90).contains(y) { return 10 }        // real content
            return 235
        }
        var o = ProcessingOptions()
        o.reduceDust = .medium
        let out = try processor.process(p, options: o)[0]
        XCTAssertGreaterThan(gray(out, 20, 20), 180)
        XCTAssertGreaterThan(gray(out, 90, 30), 180)
        XCTAssertLessThan(gray(out, 55, 75), 40)
    }

    func testReduceShowThroughWhitensPaper() throws {
        let p = try page(width: 200, height: 200) { x, y in
            if (20..<60).contains(x) && (20..<30).contains(y) { return 25 }        // printed text
            if (100..<180).contains(x) && (100..<140).contains(y) { return 185 }   // faint reverse side
            return 205                                                             // grey-ish paper
        }
        var o = ProcessingOptions()
        o.reduceShowThrough = true
        let out = try processor.process(p, options: o)[0]
        XCTAssertGreaterThan(gray(out, 150, 50), 250, "paper should become white")
        XCTAssertGreaterThan(gray(out, 140, 120), 235, "show-through should mostly disappear")
        XCTAssertLessThan(gray(out, 40, 25), 90, "text should stay dark")
    }

    func testRotationAndGrayOutput() throws {
        let p = try page(width: 100, height: 50) { _, _ in 128 }
        var o = ProcessingOptions()
        o.rotation = 90
        o.outputColor = .gray
        let out = try processor.process(p, options: o)[0]
        XCTAssertEqual(out.image.width, 50)
        XCTAssertEqual(out.image.height, 100)
        XCTAssertEqual(out.image.colorSpace?.model, .monochrome)
    }

    func testSearchablePDFContainsRecognisedText() throws {
        // Render a line of large text and run it through OCR into a PDF.
        let w = 1200, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 90, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "HELLO SCANNER",
                                                                       attributes: [.init(kCTFontAttributeName as String): font]))
        ctx.textPosition = CGPoint(x: 60, y: 110)
        CTLineDraw(line, ctx)
        let image = ProcessedImage(image: ctx.makeImage()!, dpi: 300)

        let pdf = try DocumentWriter.pdf([image], searchable: true)
        let text = PDFDocument(data: pdf)?.string ?? ""
        XCTAssertTrue(text.uppercased().contains("HELLO"), "OCR text layer missing, got: \(text)")
    }
}
