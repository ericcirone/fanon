import Foundation
import CoreGraphics
import CoreImage
import Vision

extension ImageProcessor {
    // MARK: - Curved pages

    /// Straightens text lines that bend (typically toward a book's spine).
    ///
    /// The page is cut into narrow vertical strips. For each pair of neighbouring strips, the row profiles of
    /// dark pixels are cross-correlated window by window down the page, which gives how far the text in one
    /// strip sits above or below the next. Summing those steps outward from the middle strip gives a vertical
    /// displacement field, and each column is resampled so every line lands at the height it has in the middle.
    func flattenCurvedLines(_ image: CIImage, dpi: Int) -> CIImage {
        let e = image.extent
        guard let r = raster(image, maxSide: Double(max(e.width, e.height)) * min(1, 150 / Double(max(dpi, 1)))) else {
            return image
        }
        let workDPI = Double(dpi) * r.scale
        let dark = UInt8(clamping: Int(Double(r.paperLevel()) * 0.65))
        let strips = min(24, max(6, Int(Double(r.width) / workDPI * 2)))
        let stripW = r.width / strips
        guard stripW >= 4 else { return image }

        // Dark-pixel count per row in each strip, lightly smoothed.
        var profiles = [[Double]](repeating: [Double](repeating: 0, count: r.height), count: strips)
        for k in 0..<strips {
            for y in 0..<r.height {
                var n = 0
                for x in (k * stripW)..<((k + 1) * stripW) where r[x, y] < dark { n += 1 }
                profiles[k][y] = Double(n)
            }
            let p = profiles[k]
            for y in 1..<(r.height - 1) { profiles[k][y] = (p[y - 1] + 2 * p[y] + p[y + 1]) / 4 }
        }

        let window = Int(1.2 * workDPI), step = max(1, Int(0.4 * workDPI)), maxShift = max(2, Int(0.08 * workDPI))
        let centers = Array(Swift.stride(from: window / 2, to: r.height - window / 2, by: step))
        guard centers.count >= 2 else { return image }
        let minInk = 0.05 * Double(stripW * window)

        // steps[k][j]: shift of strip k+1 relative to strip k around window j (nil when there's too little text).
        var steps = [[Double?]](repeating: [Double?](repeating: nil, count: centers.count), count: strips - 1)
        for k in 0..<(strips - 1) {
            let a = profiles[k], b = profiles[k + 1]
            for (j, c) in centers.enumerated() {
                let lo = max(maxShift, c - window / 2), hi = min(r.height - maxShift, c + window / 2)
                guard hi > lo else { continue }
                var inkA = 0.0, inkB = 0.0
                for y in lo..<hi { inkA += a[y]; inkB += b[y] }
                guard inkA > minInk, inkB > minInk else { continue }
                var scores: [Double] = []
                for d in -maxShift...maxShift {
                    var sab = 0.0, saa = 0.0, sbb = 0.0
                    for y in lo..<hi {
                        sab += a[y] * b[y + d]; saa += a[y] * a[y]; sbb += b[y + d] * b[y + d]
                    }
                    scores.append(sab / max(1e-9, (saa * sbb).squareRoot()))
                }
                let bestIndex = scores.indices.max { scores[$0] < scores[$1] }!
                // A peak at the end of the search range is probably the neighbouring line of text.
                guard scores[bestIndex] > 0.7, bestIndex > 0, bestIndex < scores.count - 1 else { continue }
                var d = Double(bestIndex - maxShift)
                if bestIndex > 0, bestIndex < scores.count - 1 {   // sub-pixel peak
                    let l = scores[bestIndex - 1], m = scores[bestIndex], rr = scores[bestIndex + 1]
                    let denom = l - 2 * m + rr
                    if denom < 0 { d += 0.5 * (l - rr) / denom }
                }
                steps[k][j] = d
            }
        }

        // Fill gaps by interpolating down each strip pair; pairs with no text count as flat.
        let filled: [[Double]] = steps.map { column in
            let known = column.enumerated().compactMap { j, v in v.map { (j, $0) } }
            guard !known.isEmpty else { return [Double](repeating: 0, count: column.count) }
            return column.indices.map { j in
                if let v = column[j] { return v }
                let before = known.last { $0.0 < j }, after = known.first { $0.0 > j }
                switch (before, after) {
                case let (b?, a?): return b.1 + (a.1 - b.1) * Double(j - b.0) / Double(a.0 - b.0)
                case let (b?, nil): return b.1
                case let (nil, a?): return a.1
                default: return 0
                }
            }
        }
        guard steps.joined().contains(where: { $0 != nil }) else { return image }

        // Offsets per strip, relative to the middle strip.
        let mid = strips / 2
        var offsets = [[Double]](repeating: [Double](repeating: 0, count: centers.count), count: strips)
        for k in (mid + 1)..<strips { for j in centers.indices { offsets[k][j] = offsets[k - 1][j] + filled[k - 1][j] } }
        for k in Swift.stride(from: mid - 1, through: 0, by: -1) {
            for j in centers.indices { offsets[k][j] = offsets[k + 1][j] - filled[k][j] }
        }
        let largest = offsets.joined().map(abs).max() ?? 0
        guard largest >= 0.75 else { return image }   // already flat

        // Resample at full resolution: out(x, y) = in(x, y + offset(x, y)).
        let w = Int(e.width), h = Int(e.height)
        var src = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &src, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: sRGB)
        var dst = src
        let toFull = 1 / r.scale
        let stripCenters = (0..<strips).map { (Double($0) + 0.5) * Double(stripW) * toFull }
        let windowCenters = centers.map { Double($0) * toFull }
        /// Neighbouring sample indices and blend factor for a position.
        func bracket(_ positions: [Double], _ v: Double) -> (Int, Int, Double) {
            if v <= positions[0] { return (0, 0, 0) }
            if v >= positions[positions.count - 1] { return (positions.count - 1, positions.count - 1, 0) }
            var i = 0
            while positions[i + 1] < v { i += 1 }
            return (i, i + 1, (v - positions[i]) / (positions[i + 1] - positions[i]))
        }
        let rows = (0..<h).map { bracket(windowCenters, Double($0)) }
        var columnOffsets = [Double](repeating: 0, count: centers.count)
        for x in 0..<w {
            let (k0, k1, fx) = bracket(stripCenters, Double(x))
            for j in centers.indices {
                columnOffsets[j] = (offsets[k0][j] * (1 - fx) + offsets[k1][j] * fx) * toFull
            }
            for y in 0..<h {
                let (j0, j1, fy) = rows[y]
                let sy = Double(y) + columnOffsets[j0] * (1 - fy) + columnOffsets[j1] * fy
                let y0 = min(max(0, Int(sy.rounded(.down))), h - 1), y1 = min(y0 + 1, h - 1)
                let t = min(max(0, sy - Double(y0)), 1)
                let di = (y * w + x) * 4, s0 = (y0 * w + x) * 4, s1 = (y1 * w + x) * 4
                for c in 0..<4 {
                    dst[di + c] = UInt8((Double(src[s0 + c]) * (1 - t) + Double(src[s1 + c]) * t).rounded())
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(dst) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGB,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return image }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
    }

    // MARK: - Page checks

    /// True when a page has (almost) nothing printed on it. The outer 6% is ignored so edge shadows don't count.
    func isBlank(_ image: CIImage) -> Bool {
        guard let r = raster(image, maxSide: 600) else { return false }
        let paper = r.paperLevel(0.6)
        let bx = r.width * 6 / 100, by = r.height * 6 / 100
        var ink = 0, total = 0
        for y in by..<(r.height - by) {
            for x in bx..<(r.width - bx) {
                total += 1
                let i = y * r.width + x
                if abs(Int(r.luma[i]) - paper) > 45 || r.chroma[i] > 60 { ink += 1 }
            }
        }
        return total > 0 && Double(ink) / Double(total) < 0.0008
    }

    /// True when the page has noticeable colour (rather than black/grey print on plain paper).
    func isColorful(_ image: CIImage) -> Bool {
        guard let r = raster(image, maxSide: 500) else { return true }
        let colourful = r.chroma.filter { $0 > 40 }.count
        return Double(colourful) / Double(r.chroma.count) > 0.003
    }

    /// The clockwise rotation (0, 90, 180 or 270) that makes the text upright. 0 when there isn't enough
    /// text to tell. Text recognition finds which way the lines run (it reads upside-down text almost as well
    /// as upright text), then ascenders versus descenders tell which way is up.
    func uprightRotation(_ image: CIImage) -> Int {
        let e = image.extent
        let s = min(1, 1600 / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let cg = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: sRGB) else { return 0 }
        let orientations: [(Int, CGImagePropertyOrientation)] = [(0, .up), (90, .right), (180, .down), (270, .left)]
        let scores = orientations.map { degrees, orientation -> Double in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:]).perform([request])
            return (request.results ?? []).reduce(0.0) { sum, obs in
                guard let top = obs.topCandidates(1).first else { return sum }
                return sum + Double(top.confidence) * Double(top.string.filter { $0.isLetter }.count)
            }
        }
        let horizontal = scores[0] + scores[2], vertical = scores[1] + scores[3]
        guard max(horizontal, vertical) >= 20 else { return 0 }
        let base = horizontal >= vertical ? 0 : 90
        let ratio = ascenderRatio(rotate(small, degrees: base))
        if ratio < 1 / 1.25 { return base + 180 }
        if ratio > 1.25 { return base }
        // Undecided: only turn a page whose lines run the other way.
        return base == 0 ? 0 : (scores[1] >= scores[3] ? 90 : 270)
    }

    /// Ink just above the main body of each text line divided by ink just below it. Latin script has far
    /// more ascenders and capitals than descenders, so upright text gives a ratio well above 1.
    func ascenderRatio(_ image: CIImage) -> Double {
        guard let r = raster(image, maxSide: 1600) else { return 1 }
        let dark = UInt8(clamping: Int(Double(r.paperLevel()) * 0.6))
        let profile = (0..<r.height).map { y in (0..<r.width).reduce(0) { $0 + (r[$1, y] < dark ? 1 : 0) } }
        let floor = max(1, (profile.max() ?? 0) / 100)
        var above = 0, below = 0
        var y = 0
        while y < r.height {
            guard profile[y] > floor else { y += 1; continue }
            var end = y
            while end + 1 < r.height, profile[end + 1] > floor { end += 1 }
            let line = y...end
            let peak = line.map { profile[$0] }.max()!
            if let bodyTop = line.first(where: { profile[$0] >= peak * 4 / 10 }),
               let bodyBottom = line.last(where: { profile[$0] >= peak * 4 / 10 }), line.count >= 5 {
                above += (y..<bodyTop).reduce(0) { $0 + profile[$1] }
                below += ((bodyBottom + 1)..<(end + 1)).reduce(0) { $0 + profile[$1] }
            }
            y = end + 1
        }
        return Double(above + 1) / Double(below + 1)
    }

    // MARK: - Book spreads

    /// Splits a landscape two-page spread at the spine: the darkest column near the middle, or the centre.
    func splitSpread(_ image: CIImage) -> [CIImage] {
        let e = image.extent
        guard e.width > e.height * 1.15 else { return [image] }
        var cut = e.width / 2
        if let r = raster(image, maxSide: 800) {
            var columns = (0..<r.width).map { x in
                (0..<r.height).reduce(0.0) { $0 + Double(r[x, $1]) } / Double(r.height)
            }
            let c = columns
            for x in 2..<(r.width - 2) { columns[x] = (c[x - 2] + c[x - 1] + c[x] + c[x + 1] + c[x + 2]) / 5 }
            let lo = r.width * 35 / 100, hi = r.width * 65 / 100
            let median = columns.sorted()[columns.count / 2]
            if let x = (lo..<hi).min(by: { columns[$0] < columns[$1] }), columns[x] < median * 0.95 {
                cut = CGFloat(Double(x) + 0.5) / CGFloat(r.scale)
            }
        }
        let left = image.cropped(to: CGRect(x: e.minX, y: e.minY, width: cut.rounded(), height: e.height))
        let right = image.cropped(to: CGRect(x: e.minX + cut.rounded(), y: e.minY, width: e.width - cut.rounded(), height: e.height))
        return [left, right.transformed(by: CGAffineTransform(translationX: -cut.rounded(), y: 0))]
    }
}
