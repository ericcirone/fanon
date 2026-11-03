import Foundation

/// Image corrections applied after scanning, modelled on the options Canon's IJ Scanner driver offered,
/// plus a few from current document-scanning software.
public struct ProcessingOptions: Codable, Equatable, Sendable {
    public enum Level: String, Codable, CaseIterable, Sendable, Identifiable {
        case none, low, medium, high
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
        /// 0 for none, then 1...3.
        public var strength: Int { Self.allCases.firstIndex(of: self)! }
    }

    public enum AutoCrop: String, Codable, CaseIterable, Sendable, Identifiable {
        case none, straighten, document, separateItems
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .none: return "None"
            case .straighten: return "Straighten Only"
            case .document: return "Straighten & Crop Document"
            case .separateItems: return "Detect Separate Items"
            }
        }
    }

    public enum OutputColor: String, Codable, CaseIterable, Sendable, Identifiable {
        case auto, color, gray, blackAndWhite
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .auto: return "Automatic (Color or Gray)"
            case .color: return "Color"
            case .gray: return "Grayscale"
            case .blackAndWhite: return "Black & White"
            }
        }
    }

    /// "Image Adjustment: Auto": automatic tone, exposure and colour balance.
    public var autoAdjust = false
    public var unsharpMask = false
    /// Removes halftone (moiré) patterns from printed material.
    public var descreen = false
    /// Whitens the paper so text printed on the reverse side doesn't show through.
    public var reduceShowThrough = false
    /// Removes small specks of dust and fine scratches (best for photos).
    public var reduceDust: Level = .none
    /// Restores colour and contrast of faded photos.
    public var fadingCorrection: Level = .none
    /// Smooths film grain and scanner noise.
    public var grainCorrection: Level = .none
    /// Brightens the shadow along a book's spine or a page edge.
    public var gutterCorrection = false
    /// Straightens text lines that curve toward a book's spine.
    public var flattenCurvedPages = false
    /// Splits a two-page book spread into separate pages.
    public var splitFacingPages = false
    public var autoCrop: AutoCrop = .none
    /// Exact corners to crop to (normalised, top-left origin), e.g. from the preview's "Detect Document".
    /// Takes precedence over `autoCrop`.
    public var cropQuad: Quad?
    /// Turns pages upright by reading the direction of their text.
    public var autoRotate = false
    /// Clockwise rotation in degrees (0, 90, 180, 270), applied after `autoRotate`.
    public var rotation = 0
    /// Rotates the back side of duplex sheets by 180°.
    public var rotateBackSides = false
    /// Drops pages with nothing on them (handy for double-sided feeder scans).
    public var skipBlankPages = false
    public var outputColor: OutputColor = .color

    public init() {}

    /// Older saved settings lack newer keys, so every field falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func load<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { value = v }
        }
        load(.autoAdjust, &autoAdjust)
        load(.unsharpMask, &unsharpMask)
        load(.descreen, &descreen)
        load(.reduceShowThrough, &reduceShowThrough)
        load(.reduceDust, &reduceDust)
        load(.fadingCorrection, &fadingCorrection)
        load(.grainCorrection, &grainCorrection)
        load(.gutterCorrection, &gutterCorrection)
        load(.flattenCurvedPages, &flattenCurvedPages)
        load(.splitFacingPages, &splitFacingPages)
        load(.autoCrop, &autoCrop)
        cropQuad = try? c.decodeIfPresent(Quad.self, forKey: .cropQuad)
        load(.autoRotate, &autoRotate)
        load(.rotation, &rotation)
        load(.rotateBackSides, &rotateBackSides)
        load(.skipBlankPages, &skipBlankPages)
        load(.outputColor, &outputColor)
    }

    /// Options that only change tone and colour, safe to show on the preview without moving anything.
    public var toneOnly: ProcessingOptions {
        var o = self
        o.autoCrop = .none
        o.cropQuad = nil
        o.autoRotate = false
        o.rotation = 0
        o.splitFacingPages = false
        o.flattenCurvedPages = false
        o.skipBlankPages = false
        return o
    }
}
