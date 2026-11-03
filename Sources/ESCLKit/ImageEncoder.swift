import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PixmaKit

public enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case pdf = "application/pdf"
    case tiff = "image/tiff"

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .pdf: return "pdf"
        case .tiff: return "tiff"
        }
    }

    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "png": self = .png
        case "pdf": self = .pdf
        case "tif", "tiff": self = .tiff
        default: return nil
        }
    }
}

public enum ImageEncoder {
    public static func cgImage(_ page: ScannedPage) -> CGImage? {
        let colorSpace = page.channels == 3 ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: page.pixels as CFData) else { return nil }
        return CGImage(width: page.width, height: page.height, bitsPerComponent: 8,
                       bitsPerPixel: 8 * page.channels, bytesPerRow: page.width * page.channels,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Encodes pages into a single document. JPEG and PNG hold one page; PDF and TIFF hold all.
    public static func encode(_ pages: [ScannedPage], as format: ImageFormat, jpegQuality: Double = 0.9) throws -> Data {
        guard let first = pages.first else { throw PixmaError.invalidParameter("no pages to encode") }
        if format == .pdf { return try pdf(pages, jpegQuality: jpegQuality) }

        let type: UTType = format == .jpeg ? .jpeg : format == .png ? .png : .tiff
        let output = NSMutableData()
        let toEncode = format == .tiff ? pages : [first]
        guard let dest = CGImageDestinationCreateWithData(output, type.identifier as CFString, toEncode.count, nil) else {
            throw PixmaError.invalidParameter("cannot create \(format.rawValue) encoder")
        }
        for page in toEncode {
            guard let image = cgImage(page) else { throw PixmaError.invalidParameter("cannot build image") }
            var props: [CFString: Any] = [
                kCGImagePropertyDPIWidth: page.dpi,
                kCGImagePropertyDPIHeight: page.dpi,
            ]
            if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw PixmaError.invalidParameter("encoding failed") }
        return output as Data
    }

    /// Builds a PDF with one JPEG-compressed page per scanned page, sized to the physical page.
    private static func pdf(_ pages: [ScannedPage], jpegQuality: Double) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PixmaError.invalidParameter("cannot create PDF context")
        }
        for page in pages {
            // Re-decode a JPEG so the PDF stores DCT-compressed images instead of raw pixels.
            let jpeg = try encode([page], as: .jpeg, jpegQuality: jpegQuality)
            guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw PixmaError.invalidParameter("cannot build PDF page")
            }
            var box = CGRect(x: 0, y: 0,
                             width: Double(page.width) * 72 / Double(page.dpi),
                             height: Double(page.height) * 72 / Double(page.dpi))
            ctx.beginPage(mediaBox: &box)
            ctx.draw(image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
        return output as Data
    }
}
