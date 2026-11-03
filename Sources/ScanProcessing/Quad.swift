import CoreGraphics

/// Four corners of a page or photo, normalised to the image (0...1) with the origin at the top left.
public struct Quad: Codable, Equatable, Sendable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public init(rect r: CGRect) {
        self.init(topLeft: CGPoint(x: r.minX, y: r.minY), topRight: CGPoint(x: r.maxX, y: r.minY),
                  bottomRight: CGPoint(x: r.maxX, y: r.maxY), bottomLeft: CGPoint(x: r.minX, y: r.maxY))
    }

    /// Corners in any order (as long as they form a convex quadrilateral rotated less than 45°).
    init(corners: [CGPoint]) {
        let bySum = corners.sorted { $0.x + $0.y < $1.x + $1.y }
        let rest = [bySum[1], bySum[2]].sorted { $0.x - $0.y > $1.x - $1.y }
        self.init(topLeft: bySum[0], topRight: rest[0], bottomRight: bySum[3], bottomLeft: rest[1])
    }

    /// Clockwise from the top left.
    public var points: [CGPoint] {
        get { [topLeft, topRight, bottomRight, bottomLeft] }
        set { (topLeft, topRight, bottomRight, bottomLeft) = (newValue[0], newValue[1], newValue[2], newValue[3]) }
    }

    public var boundingBox: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    public func mapped(_ transform: (CGPoint) -> CGPoint) -> Quad {
        Quad(topLeft: transform(topLeft), topRight: transform(topRight),
             bottomRight: transform(bottomRight), bottomLeft: transform(bottomLeft))
    }

    /// Pulls each corner toward the centre by about `pixels`, so a crop doesn't keep a sliver of the lid.
    func insetForCrop(_ size: CGSize, pixels: CGFloat) -> Quad {
        let c = CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
        return mapped { p in
            let dx = (c.x - p.x) * size.width, dy = (c.y - p.y) * size.height
            let len = max(hypot(dx, dy), 1)
            return CGPoint(x: p.x + dx / len * pixels * 1.4 / size.width, y: p.y + dy / len * pixels * 1.4 / size.height)
        }
    }

    /// Clockwise tilt of the top edge, in degrees.
    public var angle: Double {
        Double(atan2(topRight.y - topLeft.y, topRight.x - topLeft.x)) * 180 / .pi
    }
}

enum PlaneGeometry {
    /// Convex hull (Andrew's monotone chain).
    static func convexHull(_ input: [CGPoint]) -> [CGPoint] {
        let pts = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard pts.count > 2 else { return pts }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// The smallest rectangle (any rotation) containing the points: rotating calipers over the hull edges.
    static func minAreaRect(_ points: [CGPoint]) -> [CGPoint]? {
        let hull = convexHull(points)
        guard hull.count >= 3 else { return nil }
        var best: (area: CGFloat, corners: [CGPoint])?
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0 else { continue }
            let u = CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len)
            let v = CGPoint(x: -u.y, y: u.x)
            var minU = CGFloat.infinity, maxU = -CGFloat.infinity, minV = CGFloat.infinity, maxV = -CGFloat.infinity
            for p in hull {
                let pu = (p.x - a.x) * u.x + (p.y - a.y) * u.y
                let pv = (p.x - a.x) * v.x + (p.y - a.y) * v.y
                minU = min(minU, pu); maxU = max(maxU, pu)
                minV = min(minV, pv); maxV = max(maxV, pv)
            }
            let area = (maxU - minU) * (maxV - minV)
            if best == nil || area < best!.area {
                func at(_ s: CGFloat, _ t: CGFloat) -> CGPoint {
                    CGPoint(x: a.x + u.x * s + v.x * t, y: a.y + u.y * s + v.y * t)
                }
                best = (area, [at(minU, minV), at(maxU, minV), at(maxU, maxV), at(minU, maxV)])
            }
        }
        return best?.corners
    }
}
