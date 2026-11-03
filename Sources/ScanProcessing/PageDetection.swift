import Foundation
import CoreGraphics
import CoreImage

/// A downscaled 8-bit copy of an image for analysis: luminance and chroma, row 0 at the top.
struct Raster {
    let width: Int
    let height: Int
    /// Analysis pixels per source pixel.
    let scale: Double
    var luma: [UInt8]
    var chroma: [UInt8]

    subscript(x: Int, y: Int) -> UInt8 { luma[y * width + x] }

    /// The paper brightness: a high percentile of luminance.
    func paperLevel(_ p: Double = 0.9) -> Int {
        var hist = [Int](repeating: 0, count: 256)
        for v in luma { hist[Int(v)] += 1 }
        return ImageProcessor.percentile(hist, p, luma.count)
    }
}

extension ImageProcessor {
    func raster(_ image: CIImage, maxSide: Double) -> Raster? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite else { return nil }
        let s = min(1, maxSide / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let w = Int(small.extent.width.rounded(.down)), h = Int(small.extent.height.rounded(.down))
        guard w > 2, h > 2 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &rgba, rowBytes: w * 4,
                       bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                       format: .RGBA8, colorSpace: sRGB)
        var luma = [UInt8](repeating: 0, count: w * h), chroma = luma
        for i in 0..<(w * h) {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            luma[i] = UInt8((r * 3 + g * 6 + b) / 10)
            chroma[i] = UInt8(max(r, g, b) - min(r, g, b))
        }
        return Raster(width: w, height: h, scale: Double(s), luma: luma, chroma: chroma)
    }

    // MARK: - Finding pages and photos on the glass

    /// Finds the page on the glass. Works on what differs from the white lid (colour, edges and print), so it
    /// handles pages touching the edge of the glass. White pages whose edges don't show are matched to a
    /// standard paper size placed against the corner mark. Returns nil if there's nothing to find.
    public func detectDocument(_ image: CIImage, dpi: Int) -> Quad? {
        guard let r = raster(image, maxSide: analysisSide(image, dpi: dpi)) else { return nil }
        let w = r.width, h = r.height
        let workDPI = Double(dpi) * r.scale
        var (fg, inner) = foreground(r, workDPI: workDPI)
        removeSpecks(&fg, w, h, maxPixels: max(4, Int(pow(0.05 * workDPI, 2))))
        let closed = close(fg, w, h, radius: max(2, Int(0.1 * workDPI)))
        let minPixels = Int(pow(0.15 * workDPI, 2))
        let comps = components(closed, w, h).filter { $0.count >= minPixels }
        guard !comps.isEmpty else { return nil }
        let all = comps.flatMap { $0 }
        let hull = PlaneGeometry.convexHull(outline(all, w))
        guard hull.count >= 3 else { return nil }

        // The angle comes from the outline away from the glass border: a page that runs off the glass on
        // three sides still shows its tilt along the fourth.
        var inside = [Bool](repeating: false, count: w * h)
        for i in all { inside[i] = true }
        let away = inner.insetBy(dx: 4, dy: 4)
        var edges: [CGPoint] = []
        for i in all {
            let x = i % w, y = i / w
            guard away.contains(CGPoint(x: x, y: y)) else { continue }
            if !inside[i - 1] || !inside[i + 1] || !inside[i - w] || !inside[i + w] {
                edges.append(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
            }
        }
        let angle = dominantEdgeAngle(edges, w, h, minLength: Int(workDPI))
        // The bounding box of everything found, at that angle.
        let c = cos(angle), sn = sin(angle)
        let rotated = hull.map { CGPoint(x: $0.x * c + $0.y * sn, y: -$0.x * sn + $0.y * c) }
        var box = CGRect(x: rotated.map(\.x).min()!, y: rotated.map(\.y).min()!,
                         width: rotated.map(\.x).max()! - rotated.map(\.x).min()!,
                         height: rotated.map(\.y).max()! - rotated.map(\.y).min()!)
        func unrotate(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * c - p.y * sn, y: p.x * sn + p.y * c) }

        // A tilted page that runs off the glass leaves thin wedges of lid (or of the glass edge) inside the box.
        // Pull each such side in until it lies on the page, by no more than 0.15".
        let limit = 0.15 * workDPI
        let original = box
        func sideOK(_ a: CGPoint, _ b: CGPoint) -> Bool {
            let center = CGPoint(x: box.midX, y: box.midY)
            return (0...20).allSatisfy { k in
                let t = 0.02 + 0.96 * CGFloat(k) / 20
                var p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                let d = hypot(center.x - p.x, center.y - p.y)
                p = unrotate(CGPoint(x: p.x + (center.x - p.x) / d * 2, y: p.y + (center.y - p.y) / d * 2))
                let x = Int(p.x), y = Int(p.y)
                return inner.contains(p) && x >= 0 && y >= 0 && x < w && y < h && inside[y * w + x]
            }
        }
        for _ in 0..<Int(limit * 2) {
            var moved = false
            if !sideOK(CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY)) {
                box.origin.y += 0.5; box.size.height -= 0.5; moved = true
            }
            if !sideOK(CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)) { box.size.height -= 0.5; moved = true }
            if !sideOK(CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.minX, y: box.maxY)) {
                box.origin.x += 0.5; box.size.width -= 0.5; moved = true
            }
            if !sideOK(CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)) { box.size.width -= 0.5; moved = true }
            if !moved { break }
        }
        // Sides that needed more than the limit aren't wedges (the page itself isn't a solid region); keep those.
        if box.minY - original.minY >= limit { box.origin.y = original.minY; box.size.height += box.minY - original.minY }
        if box.minX - original.minX >= limit { box.origin.x = original.minX; box.size.width += box.minX - original.minX }
        if original.maxY - box.maxY >= limit { box.size.height = original.maxY - box.minY }
        if original.maxX - box.maxX >= limit { box.size.width = original.maxX - box.minX }
        var quad = Quad(rect: box).mapped(unrotate)
        guard Double(box.width * box.height) > 0.02 * Double(w * h) else { return nil }

        if !sidesSupported(quad, fg, w, h, inner: inner) {
            // Only print was found (white paper on a white lid): assume the page sits against the corner mark
            // and is the usual paper size for the region, Letter or A4, whichever holds everything printed.
            let b = quad.boundingBox
            let maxX = Double(b.maxX) / workDPI, maxY = Double(b.maxY) / workDPI
            guard Double(b.minX) / workDPI < 1.2, Double(b.minY) / workDPI < 1.2,
                  let size = Self.documentSizes.first(where: { $0.w >= maxX - 0.02 && $0.h >= maxY - 0.02 }) else { return nil }
            let glass = (w: Double(w) / workDPI, h: Double(h) / workDPI)
            quad = Quad(rect: CGRect(x: 0, y: 0, width: min(size.w, glass.w) * workDPI, height: min(size.h, glass.h) * workDPI))
        }
        let b = quad.boundingBox
        if b.width >= CGFloat(w) - 2, b.height >= CGFloat(h) - 2, abs(quad.angle) < 0.1 { return nil }  // the whole glass
        return quad.mapped { CGPoint(x: $0.x / CGFloat(w), y: $0.y / CGFloat(h)) }
    }

    /// The clockwise tilt (radians) of the longest straight run of edge points, horizontal or vertical,
    /// found by voting over angles within ±10°. 0 when no edge is at least `minLength` long.
    private func dominantEdgeAngle(_ points: [CGPoint], _ w: Int, _ h: Int, minLength: Int) -> Double {
        guard points.count >= minLength else { return 0 }
        let span = w + h + 2
        var bins = [Int32](repeating: 0, count: span * 2)
        var best = (votes: Int32(0), angle: 0.0)
        for step in -200...200 {
            let t = Double(step) * 0.05 * .pi / 180, s = sin(t), c = cos(t)
            for vertical in [false, true] {
                for i in bins.indices { bins[i] = 0 }
                for p in points {
                    let v = vertical ? Double(p.x) * c + Double(p.y) * s : Double(p.y) * c - Double(p.x) * s
                    bins[Int(v) + span] += 1
                }
                // A line split across two bins still counts in full.
                for i in 0..<(bins.count - 1) where bins[i] + bins[i + 1] > best.votes {
                    best = (bins[i] + bins[i + 1], t)
                }
            }
        }
        return Int(best.votes) >= minLength ? best.angle : 0
    }

    /// Clears tiny isolated foreground blobs (dust on the glass or lid).
    private func removeSpecks(_ mask: inout [Bool], _ w: Int, _ h: Int, maxPixels: Int) {
        for comp in components(mask, w, h) where comp.count <= maxPixels {
            for i in comp { mask[i] = false }
        }
    }

    /// Finds separate photos or cards on the glass, in reading order.
    public func detectItems(_ image: CIImage, dpi: Int) -> [Quad] {
        guard let r = raster(image, maxSide: analysisSide(image, dpi: dpi)) else { return [] }
        let workDPI = Double(dpi) * r.scale
        let closed = close(foreground(r, workDPI: workDPI).mask, r.width, r.height, radius: max(1, Int(0.06 * workDPI)))
        let minPixels = Int(pow(0.5 * workDPI, 2))
        var quads: [Quad] = []
        for comp in components(closed, r.width, r.height) where comp.count >= minPixels {
            guard let corners = PlaneGeometry.minAreaRect(outline(comp, r.width)) else { continue }
            let q = Quad(corners: corners)
            let rectArea = hypot(q.topRight.x - q.topLeft.x, q.topRight.y - q.topLeft.y)
                * hypot(q.bottomLeft.x - q.topLeft.x, q.bottomLeft.y - q.topLeft.y)
            guard rectArea > 0, Double(comp.count) / Double(rectArea) > 0.45 else { continue }  // not a solid item
            quads.append(q)
        }
        let w = CGFloat(r.width), h = CGFloat(r.height)
        quads = quads.map { $0.mapped { CGPoint(x: $0.x / w, y: $0.y / h) } }
        // Drop items inside others, then order top to bottom, left to right.
        quads = quads.filter { q in !quads.contains { $0 != q && $0.boundingBox.contains(q.boundingBox) } }
        return quads.sorted { a, b in
            abs(a.boundingBox.midY - b.boundingBox.midY) > 0.1 ? a.boundingBox.midY < b.boundingBox.midY
                                                                : a.boundingBox.minX < b.boundingBox.minX
        }
    }

    /// Letter and A4 in inches, the region's usual size first.
    static var documentSizes: [(w: Double, h: Double)] {
        let letter = (w: 8.5, h: 11.0), a4 = (w: 8.27, h: 11.69)
        let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "CR", "GT", "PR", "DO", "SV", "PA", "NI", "HN", "BZ"]
        return letterRegions.contains(Locale.current.region?.identifier ?? "US") ? [letter, a4] : [a4, letter]
    }

    /// About 100 dpi is plenty to find edges.
    private func analysisSide(_ image: CIImage, dpi: Int) -> Double {
        Double(max(image.extent.width, image.extent.height)) * min(1, 100 / Double(max(dpi, 1)))
    }

    /// Pixels that aren't the lid: coloured, darker or lighter than the lid, or on an edge. Also returns the
    /// usable area: the dark lines some scans show along the edge of the glass are left out.
    private func foreground(_ r: Raster, workDPI: Double) -> (mask: [Bool], inner: CGRect) {
        let w = r.width, h = r.height
        // The lid: the most common bright, neutral tone.
        var hist = [Int](repeating: 0, count: 256)
        for i in 0..<(w * h) where r.chroma[i] < 16 && r.luma[i] >= 170 { hist[Int(r.luma[i])] += 1 }
        let lid = hist.indices.max { hist[$0] < hist[$1] }.flatMap { hist[$0] > 0 ? $0 : nil } ?? 250

        // Rows/columns within 0.12" of the border that are mostly dark are scanner artefacts.
        let depth = max(2, Int(0.12 * workDPI))
        func darkFraction(_ count: Int, _ pixel: (Int) -> UInt8) -> Double {
            (0..<count).filter { pixel($0) < 150 }.count.toDouble / Double(count)
        }
        // A thin margin is always skipped: some scans have a one-pixel line right at the edge.
        let minimum = max(2, Int((0.04 * workDPI).rounded(.up)))
        var top = minimum, bottom = minimum, left = minimum, right = minimum
        for k in 0..<depth {
            if darkFraction(w, { r[$0, k] }) > 0.6 { top = max(top, k + 2) }
            if darkFraction(w, { r[$0, h - 1 - k] }) > 0.6 { bottom = max(bottom, k + 2) }
            if darkFraction(h, { r[k, $0] }) > 0.6 { left = max(left, k + 2) }
            if darkFraction(h, { r[w - 1 - k, $0] }) > 0.6 { right = max(right, k + 2) }
        }
        let inner = CGRect(x: left, y: top, width: w - left - right, height: h - top - bottom)

        var fg = [Bool](repeating: false, count: w * h)
        for y in max(1, top)..<min(h - 1, h - bottom) {
            for x in max(1, left)..<min(w - 1, w - right) {
                let i = y * w + x
                let l = Int(r.luma[i])
                if abs(l - lid) > 22 || r.chroma[i] > 24 { fg[i] = true; continue }
                // Sobel gradient picks up the faint shadow along a white page's edge.
                let gx = Int(r.luma[i - w + 1]) + 2 * Int(r.luma[i + 1]) + Int(r.luma[i + w + 1])
                    - Int(r.luma[i - w - 1]) - 2 * Int(r.luma[i - 1]) - Int(r.luma[i + w - 1])
                let gy = Int(r.luma[i + w - 1]) + 2 * Int(r.luma[i + w]) + Int(r.luma[i + w + 1])
                    - Int(r.luma[i - w - 1]) - 2 * Int(r.luma[i - w]) - Int(r.luma[i - w + 1])
                if abs(gx) + abs(gy) > 60 { fg[i] = true }
            }
        }
        // The first row/column inside an artefact strip still picks up its gradient.
        for y in 0..<h {
            for x in 0..<w where fg[y * w + x] {
                let nearEdge = (y <= top + 1 && top > minimum) || (y >= h - bottom - 2 && bottom > minimum)
                    || (x <= left + 1 && left > minimum) || (x >= w - right - 2 && right > minimum)
                if nearEdge && abs(Int(r.luma[y * w + x]) - lid) <= 22 && r.chroma[y * w + x] <= 24 { fg[y * w + x] = false }
            }
        }
        return (fg, inner)
    }

    /// Morphological closing (dilate then erode) with a square of the given radius, via an integral image.
    private func close(_ mask: [Bool], _ w: Int, _ h: Int, radius: Int) -> [Bool] {
        func boxCount(_ m: [Bool]) -> (Int, Int, Int, Int) -> Int {
            var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
            for y in 0..<h {
                var row = 0
                for x in 0..<w {
                    row += m[y * w + x] ? 1 : 0
                    integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
                }
            }
            return { x0, y0, x1, y1 in
                integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
            }
        }
        func filter(_ m: [Bool], dilate: Bool) -> [Bool] {
            let count = boxCount(m)
            var out = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                let y0 = max(0, y - radius), y1 = min(h, y + radius + 1)
                for x in 0..<w {
                    let x0 = max(0, x - radius), x1 = min(w, x + radius + 1)
                    let n = count(x0, y0, x1, y1)
                    out[y * w + x] = dilate ? n > 0 : n == (x1 - x0) * (y1 - y0)
                }
            }
            return out
        }
        return filter(filter(mask, dilate: true), dilate: false)
    }

    /// Connected regions (4-connected) as lists of pixel indices.
    private func components(_ mask: [Bool], _ w: Int, _ h: Int) -> [[Int]] {
        var seen = [Bool](repeating: false, count: w * h)
        var result: [[Int]] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where mask[start] && !seen[start] {
            var comp: [Int] = []
            seen[start] = true
            stack.append(start)
            while let i = stack.popLast() {
                comp.append(i)
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let n = ny * w + nx
                    if mask[n] && !seen[n] { seen[n] = true; stack.append(n) }
                }
            }
            result.append(comp)
        }
        return result
    }

    /// The outer corners of each row's leftmost and rightmost pixel: enough to find the convex hull.
    private func outline(_ pixels: [Int], _ w: Int) -> [CGPoint] {
        var rows: [Int: (Int, Int)] = [:]
        for i in pixels {
            let x = i % w, y = i / w
            if let r = rows[y] { rows[y] = (min(r.0, x), max(r.1, x)) } else { rows[y] = (x, x) }
        }
        return rows.flatMap { y, r in
            [CGPoint(x: r.0, y: y), CGPoint(x: r.1 + 1, y: y), CGPoint(x: r.0, y: y + 1), CGPoint(x: r.1 + 1, y: y + 1)]
        }
    }

    /// True if each side of the quad lies on a visible edge (foreground inside, lid outside) or on the border
    /// of the glass, rather than just touching the outermost line of print.
    private func sidesSupported(_ q: Quad, _ fg: [Bool], _ w: Int, _ h: Int, inner: CGRect) -> Bool {
        let usable = inner.insetBy(dx: 2, dy: 2)
        let c = CGPoint(x: (q.topLeft.x + q.bottomRight.x) / 2, y: (q.topLeft.y + q.bottomRight.y) / 2)
        let pts = q.points
        func isFG(_ p: CGPoint) -> Bool? {
            let x = Int(p.x), y = Int(p.y)
            guard usable.contains(CGPoint(x: x, y: y)) else { return nil }  // at the edge of the glass
            return fg[y * w + x]
        }
        for k in 0..<4 {
            let a = pts[k], b = pts[(k + 1) % 4]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            var out = CGPoint(x: mid.x - c.x, y: mid.y - c.y)
            let len = max(hypot(out.x, out.y), 1)
            out = CGPoint(x: out.x / len, y: out.y / len)
            let samples = 40
            var good = 0
            for s in 0..<samples {
                let t = (CGFloat(s) + 0.5) / CGFloat(samples)
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                func at(_ d: CGFloat) -> CGPoint { CGPoint(x: p.x + out.x * d, y: p.y + out.y * d) }
                guard let outside = isFG(at(4)) else { good += 1; continue }   // side runs along the glass edge
                let onEdge = (-2...1).contains { isFG(at(CGFloat($0))) == true }
                if onEdge && !outside { good += 1 }
            }
            if good < samples * 6 / 10 { return false }
        }
        return true
    }

    // MARK: - Straightening by text lines

    /// The skew of the text lines in degrees (positive = content turned clockwise), or nil when there's no
    /// clear text to measure. Uses projection profiles: when the angle is right, rows of text pile up into
    /// sharp peaks.
    public func textSkew(_ image: CIImage, dpi: Int) -> Double? {
        guard let r = raster(image, maxSide: Double(max(image.extent.width, image.extent.height)) * min(1, 100 / Double(max(dpi, 1))))
        else { return nil }
        let dark = Int(Double(r.paperLevel()) * 0.6)
        var xs: [Double] = [], ys: [Double] = []
        let border = r.width / 30
        for y in border..<(r.height - border) {
            for x in border..<(r.width - border) where Int(r[x, y]) < dark {
                xs.append(Double(x)); ys.append(Double(y))
            }
        }
        guard xs.count > 400 else { return nil }
        let stride = max(1, xs.count / 60_000)
        let span = r.width + r.height + 2
        var bins = [Int32](repeating: 0, count: span * 2)

        func score(_ degrees: Double, vertical: Bool) -> Double {
            let t = degrees * .pi / 180, s = sin(t), c = cos(t)
            for i in bins.indices { bins[i] = 0 }
            var i = 0
            while i < xs.count {
                let v = vertical ? xs[i] * c - ys[i] * s : ys[i] * c - xs[i] * s
                bins[Int(v) + span] += 1
                i += stride
            }
            var sum = 0.0
            for b in bins where b > 0 { sum += Double(b) * Double(b) }
            return sum
        }

        var best: (angle: Double, vertical: Bool, sharpness: Double)?
        for vertical in [false, true] {
            let coarse = stride_(from: -10, through: 10, by: 0.25).map { ($0, score($0, vertical: vertical)) }
            let mean = coarse.map(\.1).reduce(0, +) / Double(coarse.count)
            var top = coarse.max { $0.1 < $1.1 }!
            for a in stride_(from: top.0 - 0.25, through: top.0 + 0.25, by: 0.02) {
                let s = score(a, vertical: vertical)
                if s > top.1 { top = (a, s) }
            }
            let sharpness = top.1 / mean
            if best == nil || sharpness > best!.sharpness { best = (top.0, vertical, sharpness) }
        }
        guard let best, best.sharpness > 1.15 else { return nil }
        // A vertical line leaning right going down means the content turned counter-clockwise.
        return best.vertical ? -best.angle : best.angle
    }

    private func stride_(from: Double, through: Double, by: Double) -> [Double] {
        Array(Swift.stride(from: from, through: through + by / 2, by: by))
    }

    /// Rotates by a small angle about the centre, keeping the size and filling the corners with paper colour.
    func straighten(_ image: CIImage, degrees: Double) -> CIImage {
        guard abs(degrees) >= 0.05 else { return image }
        let e = image.extent
        let paper = paperColor(image) ?? [1, 1, 1]
        // Positive skew is clockwise on screen; Core Image's y axis points up, so a positive angle turns it back.
        let t = CGAffineTransform(translationX: e.midX, y: e.midY)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -e.midX, y: -e.midY)
        let fill = CIImage(color: CIColor(red: paper[0], green: paper[1], blue: paper[2], alpha: 1, colorSpace: sRGB)!)
            .cropped(to: e)
        return image.clampedToExtent().cropped(to: e.insetBy(dx: -1, dy: -1))
            .transformed(by: t)
            .composited(over: fill)
            .cropped(to: e)
    }

    /// Crops and straightens to a quad given in normalised top-left coordinates.
    func perspectiveCorrected(_ image: CIImage, _ q: Quad) -> CIImage {
        let e = image.extent
        // Core Image's origin is at the bottom left.
        func p(_ n: CGPoint) -> CIVector { CIVector(x: e.minX + n.x * e.width, y: e.maxY - n.y * e.height) }
        // Corners that fall just outside the scan repeat the nearest edge pixels rather than going transparent.
        let out = image.clampedToExtent().applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": p(q.topLeft), "inputTopRight": p(q.topRight),
            "inputBottomLeft": p(q.bottomLeft), "inputBottomRight": p(q.bottomRight),
        ])
        let ext = CGRect(x: 0, y: 0, width: hypot(p(q.topRight).x - p(q.topLeft).x, p(q.topRight).y - p(q.topLeft).y),
                         height: hypot(p(q.bottomLeft).x - p(q.topLeft).x, p(q.bottomLeft).y - p(q.topLeft).y))
        let integral = (out.extent.isInfinite ? ext : out.extent).integral
        return out.cropped(to: integral).transformed(by: CGAffineTransform(translationX: -integral.minX, y: -integral.minY))
    }
}

private extension Int {
    var toDouble: Double { Double(self) }
}

