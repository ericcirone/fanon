import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import PixmaKit

/// A finished image ready to save, with its resolution.
public struct ProcessedImage: @unchecked Sendable {
    public let image: CGImage
    public let dpi: Int

    public init(image: CGImage, dpi: Int) {
        self.image = image
        self.dpi = dpi
    }
}

/// Applies `ProcessingOptions` to scanned pages with Core Image, Vision and a little direct pixel work.
public final class ImageProcessor: @unchecked Sendable {
    public static let shared = ImageProcessor()

    let context = CIContext(options: [.cacheIntermediates: false])
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!

    public init() {}

    /// Processes one scanned page. "Detect Separate Items" can return several images.
    public func process(_ page: ScannedPage, options: ProcessingOptions, isBackSide: Bool = false) throws -> [ProcessedImage] {
        var pixels = page.pixels
        if options.gutterCorrection {
            pixels = Self.flattenIllumination(pixels, width: page.width, height: page.height, channels: page.channels, dpi: page.dpi)
        }
        guard let base = Self.cgImage(pixels: pixels, width: page.width, height: page.height, channels: page.channels) else {
            throw PixmaError.invalidParameter("cannot build image from scan data")
        }
        var rotation = options.rotation
        if isBackSide && options.rotateBackSides { rotation += 180 }
        return try process(CIImage(cgImage: base), dpi: page.dpi, options: options, rotation: rotation)
    }

    /// Processes an image that's already decoded (used for previews and `fanon process`).
    public func process(_ input: CIImage, dpi: Int, options: ProcessingOptions, rotation: Int? = nil) throws -> [ProcessedImage] {
        let image = applyCorrections(input, dpi: dpi, options: options)

        var pieces: [CIImage]
        if let quad = options.cropQuad {
            pieces = [perspectiveCorrected(image, quad)]
        } else {
            switch options.autoCrop {
            case .none: pieces = [image]
            // Pages and text are found on the scan as it came off the glass (corrections such as
            // show-through removal can make the paper look like the lid), then applied to the corrected image.
            case .straighten: pieces = [straightenByText(image, measuredOn: input, dpi: dpi)]
            case .document:
                pieces = [cropDocument(image, measuredOn: input, dpi: dpi) ?? straightenByText(image, measuredOn: input, dpi: dpi)]
            case .separateItems:
                let items = separateItems(image, measuredOn: input, dpi: dpi)
                pieces = items.isEmpty ? [image] : items
            }
        }

        let degrees = (rotation ?? options.rotation) % 360
        pieces = pieces.map { piece in
            var p = piece
            if options.autoRotate { p = rotate(p, degrees: uprightRotation(p)) }
            return rotate(p, degrees: (degrees + 360) % 360)
        }
        if options.splitFacingPages { pieces = pieces.flatMap { splitSpread($0) } }
        if options.flattenCurvedPages { pieces = pieces.map { flattenCurvedLines($0, dpi: dpi) } }
        if options.skipBlankPages { pieces = pieces.filter { !isBlank($0) } }

        return try pieces.map { piece in
            var image = piece
            var color = options.outputColor
            if color == .auto { color = isColorful(image) ? .color : .gray }
            if color == .gray, options.outputColor == .auto { image = image.applyingFilter("CIPhotoEffectMono") }
            if color == .blackAndWhite { image = image.applyingFilter("CIColorThresholdOtsu") }
            let extent = image.extent.integral
            let cg: CGImage?
            if color == .color {
                cg = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: sRGB)
            } else {
                cg = context.createCGImage(image, from: extent, format: .L8, colorSpace: gray)
            }
            guard let cg else { throw PixmaError.invalidParameter("image processing failed") }
            return ProcessedImage(image: cg, dpi: dpi)
        }
    }

    /// Rotates a finished image by a multiple of 90° clockwise (used to fix pages after scanning).
    public func rotated(_ item: ProcessedImage, degrees: Int) -> ProcessedImage {
        let out = rotate(CIImage(cgImage: item.image), degrees: (degrees % 360 + 360) % 360)
        let space = item.image.colorSpace?.model == .monochrome ? gray : sRGB
        let format: CIFormat = space === gray ? .L8 : .RGBA8
        guard let cg = context.createCGImage(out, from: out.extent.integral, format: format, colorSpace: space) else { return item }
        return ProcessedImage(image: cg, dpi: item.dpi)
    }

    // MARK: - Corrections

    func applyCorrections(_ input: CIImage, dpi: Int, options: ProcessingOptions) -> CIImage {
        var image = input
        let scale = Double(dpi) / 300.0   // filter radii are tuned at 300 dpi

        if options.reduceDust != .none {
            image = reduceDust(image, level: options.reduceDust)
        }
        if options.descreen, dpi >= 150 {
            // Blur away the halftone dot pattern, then restore edge contrast.
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 1.2 * scale).cropped(to: image.extent)
            let f = CIFilter.unsharpMask()
            f.inputImage = blurred
            f.radius = Float(2.0 * scale)
            f.intensity = 0.5
            image = f.outputImage ?? blurred
        }
        if options.grainCorrection != .none {
            let f = CIFilter.noiseReduction()
            f.inputImage = image
            f.noiseLevel = [0, 0.015, 0.03, 0.06][options.grainCorrection.strength]
            f.sharpness = 0.4
            image = f.outputImage ?? image
        }
        if options.fadingCorrection != .none {
            image = restoreFading(image, level: options.fadingCorrection)
        }
        if options.autoAdjust {
            for filter in image.autoAdjustmentFilters(options: [.redEye: false, .features: []]) {
                filter.setValue(image, forKey: kCIInputImageKey)
                image = filter.outputImage ?? image
            }
        }
        if options.reduceShowThrough {
            image = whitenBackground(image)
        }
        if options.unsharpMask {
            let f = CIFilter.unsharpMask()
            f.inputImage = image
            f.radius = Float(2.5 * scale)
            f.intensity = 0.6
            image = f.outputImage ?? image
        }
        if options.outputColor == .gray || options.outputColor == .blackAndWhite {
            image = image.applyingFilter("CIPhotoEffectMono")
        }
        return image.cropped(to: input.extent)
    }

    /// Replaces small isolated specks (pixels that differ strongly from their median-filtered
    /// neighbourhood) with the median value, leaving everything else untouched.
    func reduceDust(_ image: CIImage, level: ProcessingOptions.Level) -> CIImage {
        var median = image
        for _ in 0..<level.strength { median = median.applyingFilter("CIMedianFilter") }
        let difference = image.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: median])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.0])
        let mask = difference.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": [0, 0.20, 0.13, 0.08][level.strength]])
        return median.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask,
        ])
    }

    /// Stretches each colour channel to its full range (fixing the colour cast of faded dyes)
    /// and boosts saturation.
    func restoreFading(_ image: CIImage, level: ProcessingOptions.Level) -> CIImage {
        let s = Double(level.strength) / 3.0
        // Statistics are measured on sRGB-encoded values, so apply the stretch in that space too
        // (Core Image's working space is linear).
        var out = image.applyingFilter("CILinearToSRGBToneCurve")
        if let stats = channelPercentiles(image, low: 0.005, high: 0.995) {
            // Blend the full correction with the original according to strength.
            let scales = (0..<3).map { c in 1.0 / max(0.05, stats.high[c] - stats.low[c]) }
            let r = 1 + (scales[0] - 1) * s, g = 1 + (scales[1] - 1) * s, b = 1 + (scales[2] - 1) * s
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputBiasVector": CIVector(x: -stats.low[0] * r, y: -stats.low[1] * g, z: -stats.low[2] * b, w: 0),
            ]).applyingFilter("CIColorClamp")
        }
        return out.applyingFilter("CISRGBToneCurveToLinear")
            .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.35 * s * 3])
    }

    /// Maps the paper colour to pure white and lifts faint tones, hiding show-through.
    func whitenBackground(_ image: CIImage) -> CIImage {
        guard let paper = paperColor(image) else { return image }
        // Work on sRGB-encoded values, matching how the paper colour was measured.
        let scaled = image.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 / max(0.3, paper[0] * 0.96), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 / max(0.3, paper[1] * 0.96), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 / max(0.3, paper[2] * 0.96), w: 0),
        ]).applyingFilter("CIColorClamp")
        // Push light greys (typical show-through) the rest of the way to white.
        return scaled.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 0.25, y: 0.22),
            "inputPoint2": CIVector(x: 0.5, y: 0.48),
            "inputPoint3": CIVector(x: 0.8, y: 0.88),
            "inputPoint4": CIVector(x: 0.9, y: 1),
        ]).applyingFilter("CISRGBToneCurveToLinear")
    }

    // MARK: - Statistics (on a small rendition)

    private func smallRGBA(_ image: CIImage, maxSide: Double = 400) -> (data: [UInt8], count: Int)? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let s = min(1, maxSide / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let w = Int(small.extent.width.rounded(.down)), h = Int(small.extent.height.rounded(.down))
        guard w > 0, h > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &data, rowBytes: w * 4,
                       bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                       format: .RGBA8, colorSpace: sRGB)
        return (data, w * h)
    }

    func channelPercentiles(_ image: CIImage, low: Double, high: Double) -> (low: [Double], high: [Double])? {
        guard let (data, n) = smallRGBA(image) else { return nil }
        var lows = [Double](), highs = [Double]()
        for c in 0..<3 {
            var hist = [Int](repeating: 0, count: 256)
            for i in 0..<n { hist[Int(data[i * 4 + c])] += 1 }
            lows.append(Double(Self.percentile(hist, low, n)) / 255)
            highs.append(Double(Self.percentile(hist, high, n)) / 255)
        }
        return (lows, highs)
    }

    /// The paper colour: the average of the brightest, most common tones.
    func paperColor(_ image: CIImage) -> [Double]? {
        guard let (data, n) = smallRGBA(image) else { return nil }
        var lumHist = [Int](repeating: 0, count: 256)
        var lum = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let l = (Int(data[i * 4]) * 3 + Int(data[i * 4 + 1]) * 6 + Int(data[i * 4 + 2])) / 10
            lum[i] = UInt8(l)
            lumHist[l] += 1
        }
        // Mode of the upper half of the histogram is the paper.
        let peak = (128..<256).max { lumHist[$0] < lumHist[$1] } ?? 255
        guard lumHist[peak] > n / 50 else { return nil }  // no clear paper background (e.g. a photo)
        var sum = [0.0, 0.0, 0.0], count = 0.0
        for i in 0..<n where abs(Int(lum[i]) - peak) <= 6 {
            for c in 0..<3 { sum[c] += Double(data[i * 4 + c]) }
            count += 1
        }
        return sum.map { $0 / count / 255 }
    }

    static func percentile(_ hist: [Int], _ p: Double, _ n: Int) -> Int {
        let target = Int(Double(n) * p)
        var acc = 0
        for (v, c) in hist.enumerated() {
            acc += c
            if acc > target { return v }
        }
        return 255
    }

    // MARK: - Geometry

    func rotate(_ image: CIImage, degrees: Int) -> CIImage {
        let orientation: CGImagePropertyOrientation
        switch degrees {
        case 90: orientation = .right
        case 180: orientation = .down
        case 270: orientation = .left
        default: return image
        }
        let rotated = image.oriented(orientation)
        return rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
    }

    /// Straightens text that was placed on the glass at a slight angle.
    func straightenByText(_ image: CIImage, measuredOn source: CIImage, dpi: Int) -> CIImage {
        guard let skew = textSkew(source, dpi: dpi) else { return image }
        return straighten(image, degrees: skew)
    }

    /// Finds the page on the glass, then crops and straightens it. Falls back to Vision's detectors.
    func cropDocument(_ image: CIImage, measuredOn source: CIImage, dpi: Int) -> CIImage? {
        if let found = detectDocument(source, dpi: dpi) {
            let quad = found.insetForCrop(image.extent.size, pixels: 1)
            let page = perspectiveCorrected(image, quad)
            // Text is often printed a little askew on the paper; level the text, which is what the eye judges.
            if let skew = textSkew(perspectiveCorrected(source, quad), dpi: dpi), abs(skew) >= 0.1, abs(skew) <= 2 {
                return straighten(page, degrees: skew)
            }
            return page
        }
        let handler = VNImageRequestHandler(ciImage: source, options: [:])
        let doc = VNDetectDocumentSegmentationRequest()
        let rect = VNDetectRectanglesRequest()
        rect.maximumObservations = 1
        rect.minimumSize = 0.2
        rect.minimumConfidence = 0.5
        rect.quadratureTolerance = 15
        try? handler.perform([doc, rect])
        let candidates = (doc.results ?? []) + (rect.results ?? [])
        guard let best = candidates.first(where: { $0.confidence > 0.5 && area($0) < 0.98 }) else { return nil }
        return perspectiveCorrected(image, Self.quad(best))
    }

    /// Finds several photos on the glass and returns each one straightened.
    func separateItems(_ image: CIImage, measuredOn source: CIImage, dpi: Int) -> [CIImage] {
        let found = detectItems(source, dpi: dpi)
        if !found.isEmpty { return found.map { perspectiveCorrected(image, $0.insetForCrop(image.extent.size, pixels: 1)) } }
        let handler = VNImageRequestHandler(ciImage: source, options: [:])
        let rect = VNDetectRectanglesRequest()
        rect.maximumObservations = 0
        rect.minimumSize = 0.08
        rect.minimumConfidence = 0.5
        rect.quadratureTolerance = 15
        rect.minimumAspectRatio = 0.2
        try? handler.perform([rect])
        var chosen: [VNRectangleObservation] = []
        // Drop nested or overlapping detections, preferring larger ones.
        for o in (rect.results ?? []).sorted(by: { area($0) > area($1) }) where area(o) < 0.95 {
            if !chosen.contains(where: { $0.boundingBox.intersects(o.boundingBox) }) { chosen.append(o) }
        }
        // Reading order: top to bottom, then left to right.
        chosen.sort { a, b in
            abs(a.boundingBox.midY - b.boundingBox.midY) > 0.1 ? a.boundingBox.midY > b.boundingBox.midY
                                                                : a.boundingBox.minX < b.boundingBox.minX
        }
        return chosen.map { perspectiveCorrected(image, Self.quad($0)) }
    }

    /// Vision's normalised bottom-left coordinates to a top-left `Quad`.
    static func quad(_ o: VNRectangleObservation) -> Quad {
        func f(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        return Quad(topLeft: f(o.topLeft), topRight: f(o.topRight), bottomRight: f(o.bottomRight), bottomLeft: f(o.bottomLeft))
    }

    private func area(_ o: VNRectangleObservation) -> CGFloat { o.boundingBox.width * o.boundingBox.height }

    // MARK: - Pixel helpers

    static func cgImage(pixels: Data, width: Int, height: Int, channels: Int) -> CGImage? {
        let space = channels == 3 ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * channels,
                       bytesPerRow: width * channels, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Gutter correction: estimates the paper brightness along each column and row (bright
    /// percentile, smoothed) and divides it out, so a darkened spine or edge becomes paper-white
    /// while text keeps its contrast.
    static func flattenIllumination(_ pixels: Data, width: Int, height: Int, channels: Int, dpi: Int) -> Data {
        var out = pixels
        let window = max(3, dpi / 8)          // ~1/8 inch smoothing
        let maxGain = 3.0

        func profile(along columns: Bool) -> [Double] {
            let count = columns ? width : height
            let other = columns ? height : width
            let step = max(1, other / 300)
            var values = [Double](repeating: 0, count: count)
            out.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                var hist = [Int](repeating: 0, count: 256)
                for i in 0..<count {
                    for k in 0..<256 { hist[k] = 0 }
                    var n = 0
                    var j = 0
                    while j < other {
                        let (x, y) = columns ? (i, j) : (j, i)
                        let base = (y * width + x) * channels
                        var l = Int(p[base])
                        if channels == 3 { l = (Int(p[base]) * 3 + Int(p[base + 1]) * 6 + Int(p[base + 2])) / 10 }
                        hist[l] += 1
                        n += 1
                        j += step
                    }
                    values[i] = Double(percentile(hist, 0.9, n))
                }
            }
            // Moving average to follow the gradual shadow, not individual lines of text.
            var smoothed = values
            var acc = 0.0
            for i in 0..<count {
                acc += values[i]
                if i >= window { acc -= values[i - window] }
                smoothed[max(0, i - window / 2)] = acc / Double(min(i + 1, window))
            }
            return smoothed
        }

        func apply(_ prof: [Double], columns: Bool) {
            let sorted = prof.sorted()
            let target = sorted[Int(Double(sorted.count - 1) * 0.95)]
            guard target > 64 else { return }
            let gains = prof.map { $0 >= target * 0.97 ? 1.0 : min(maxGain, target / max($0, 1)) }
            guard gains.contains(where: { $0 > 1.0 }) else { return }
            out.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let g = gains[columns ? x : y]
                        if g == 1.0 { continue }
                        let base = (y * width + x) * channels
                        for c in 0..<channels {
                            p[base + c] = UInt8(min(255.0, Double(p[base + c]) * g))
                        }
                    }
                }
            }
        }

        apply(profile(along: true), columns: true)
        apply(profile(along: false), columns: false)
        return out
    }
}
