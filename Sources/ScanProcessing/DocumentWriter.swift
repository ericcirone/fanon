import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Vision
import PixmaKit

public enum OutputFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case jpeg, png, tiff, pdf
    public var id: String { rawValue }
    public var title: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    /// Formats that hold several pages in one file.
    public var isMultiPage: Bool { self == .pdf || self == .tiff }
}

public enum DocumentWriter {
    /// Writes images to one file (PDF/TIFF) or returns an error if a single-page format gets several.
    public static func write(_ images: [ProcessedImage], format: OutputFormat, to url: URL,
                             searchable: Bool = false, jpegQuality: Double = 0.9) throws {
        guard !images.isEmpty else { throw PixmaError.invalidParameter("nothing to save") }
        switch format {
        case .pdf:
            try pdf(images, searchable: searchable, jpegQuality: jpegQuality).write(to: url, options: .atomic)
        case .jpeg, .png, .tiff:
            let type: UTType = format == .jpeg ? .jpeg : format == .png ? .png : .tiff
            let toWrite = format == .tiff ? images : [images[0]]
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, toWrite.count, nil) else {
                throw PixmaError.invalidParameter("cannot write \(url.lastPathComponent)")
            }
            for item in toWrite {
                var props: [CFString: Any] = [kCGImagePropertyDPIWidth: item.dpi, kCGImagePropertyDPIHeight: item.dpi]
                if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
                if format == .tiff {
                    props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]  // LZW
                }
                CGImageDestinationAddImage(dest, item.image, props as CFDictionary)
            }
            guard CGImageDestinationFinalize(dest) else { throw PixmaError.invalidParameter("cannot write \(url.lastPathComponent)") }
        }
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Builds a PDF with one page per image. With `searchable`, recognised text is laid over each
    /// page invisibly so the PDF can be searched and text can be selected and copied.
    public static func pdf(_ images: [ProcessedImage], searchable: Bool, jpegQuality: Double = 0.9) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PixmaError.invalidParameter("cannot create PDF")
        }
        for item in images {
            // Embed as JPEG (DCT) so the PDF stays small.
            let embedded: CGImage
            if let jpeg = jpegData(item.image, quality: jpegQuality),
               let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
               let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                embedded = decoded
            } else {
                embedded = item.image
            }
            var box = CGRect(x: 0, y: 0, width: Double(item.image.width) * 72 / Double(item.dpi),
                             height: Double(item.image.height) * 72 / Double(item.dpi))
            ctx.beginPage(mediaBox: &box)
            ctx.draw(embedded, in: box)
            if searchable { drawInvisibleText(recognizeText(item.image), in: box, context: ctx) }
            ctx.endPage()
        }
        ctx.closePDF()
        return output as Data
    }

    public struct TextLine {
        public let text: String
        /// Normalised (0...1) bounding box, origin bottom-left.
        public let box: CGRect
    }

    public static func recognizeText(_ image: CGImage) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return TextLine(text: candidate.string, box: obs.boundingBox)
        }
    }

    static func drawInvisibleText(_ lines: [TextLine], in page: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(x: page.minX + line.box.minX * page.width, y: page.minY + line.box.minY * page.height,
                              width: line.box.width * page.width, height: line.box.height * page.height)
            guard rect.width > 1, rect.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.8, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [.init(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard natural > 0 else { continue }
            ctx.saveGState()
            // Stretch the line horizontally so selection boxes match the printed words.
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.2)
            ctx.scaleBy(x: rect.width / natural, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}
