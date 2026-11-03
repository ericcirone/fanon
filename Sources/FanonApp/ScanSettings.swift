import Foundation
import PixmaKit
import ScanProcessing

enum SourceChoice: String, Codable, CaseIterable, Identifiable {
    case flatbed, feeder, duplex
    var id: String { rawValue }
    var title: String {
        switch self {
        case .flatbed: return "Flatbed"
        case .feeder: return "Document Feeder"
        case .duplex: return "Document Feeder (Both Sides)"
        }
    }
    var scanSource: ScanSource { self == .flatbed ? .flatbed : self == .feeder ? .adf : .adfDuplex }
}

/// Paper sizes in 1/300 inch.
enum PaperSize: String, Codable, CaseIterable, Identifiable {
    case fullGlass, letter, a4, legal, photo4x6, photo5x7, selection
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fullGlass: return "Entire Glass"
        case .letter: return "US Letter"
        case .a4: return "A4"
        case .legal: return "US Legal"
        case .photo4x6: return "Photo 4 × 6 in"
        case .photo5x7: return "Photo 5 × 7 in"
        case .selection: return "Preview Selection"
        }
    }

    func size(for source: SourceChoice) -> (w: Int, h: Int) {
        let model = ScannerModel.mx920
        switch self {
        case .fullGlass, .selection:
            return (model.maxWidth300, source == .flatbed ? model.maxFlatbedHeight300 : model.maxADFHeight300)
        case .letter: return (2550, 3300)
        case .a4: return (2480, 3508)
        case .legal: return (2550, 4200)
        case .photo4x6: return (1200, 1800)
        case .photo5x7: return (1500, 2100)
        }
    }

    static func available(for source: SourceChoice) -> [PaperSize] {
        source == .flatbed ? [.fullGlass, .letter, .a4, .photo4x6, .photo5x7, .selection] : [.letter, .a4, .legal]
    }
}

/// JPEG compression used inside PDFs and JPEG files.
enum Compression: String, Codable, CaseIterable, Identifiable {
    case smaller, standard, best
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smaller: return "Smaller File"
        case .standard: return "Standard"
        case .best: return "Best Quality"
        }
    }
    var jpegQuality: Double { [.smaller: 0.6, .standard: 0.8, .best: 0.92][self]! }
}

/// Everything the user can set, persisted between launches.
struct ScanSettings: Codable, Equatable {
    var source: SourceChoice = .flatbed
    var color: ProcessingOptions.OutputColor = .color
    var dpi = 300
    var paper: PaperSize = .fullGlass
    /// Selection on the glass in 1/300 inch, top-left origin.
    var selection: CGRect?
    /// Exact page corners on the glass (1/300 inch, top-left origin) from "Detect Document" or dragging the
    /// corner handles. Only used while `paper` is `.selection`.
    var documentQuad: Quad?
    var calibrateEveryScan = false
    var processing = ProcessingOptions()
    var format: OutputFormat = .pdf
    var searchablePDF = true
    var compression: Compression = .standard
    /// Name for saved files; {date} and {time} are filled in.
    var baseName = "Scan {date}"
    var folderPath = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!.path
    var openAfterScan = true
    /// Keep scanned pages in a tray (to add more, reorder, rotate or delete) and save them together.
    var collectPages = false
    var previewCorrections = true
    var scannerAddress = ""

    init() {}

    /// Settings saved by older versions lack newer keys, so each field falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func load<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { value = v }
        }
        load(.source, &source)
        load(.color, &color)
        load(.dpi, &dpi)
        load(.paper, &paper)
        selection = try? c.decodeIfPresent(CGRect.self, forKey: .selection)
        documentQuad = try? c.decodeIfPresent(Quad.self, forKey: .documentQuad)
        load(.calibrateEveryScan, &calibrateEveryScan)
        load(.processing, &processing)
        load(.format, &format)
        load(.searchablePDF, &searchablePDF)
        load(.compression, &compression)
        load(.baseName, &baseName)
        load(.folderPath, &folderPath)
        load(.openAfterScan, &openAfterScan)
        load(.collectPages, &collectPages)
        load(.previewCorrections, &previewCorrections)
        load(.scannerAddress, &scannerAddress)
    }

    static let resolutionsFlatbed = [75, 150, 300, 600, 1200]
    static let resolutionsFeeder = [75, 150, 300, 600]
    var resolutions: [Int] { source == .flatbed ? Self.resolutionsFlatbed : Self.resolutionsFeeder }

    /// The scan area in 1/300 inch.
    var region: CGRect {
        if source == .flatbed, paper == .selection, let selection { return selection }
        let s = paper.size(for: source)
        return CGRect(x: 0, y: 0, width: s.w, height: s.h)
    }

    /// The page corners in use, if any.
    var activeQuad: Quad? { source == .flatbed && paper == .selection ? documentQuad : nil }

    func scanRequest() -> ScanRequest {
        var r = ScanRequest()
        r.source = source.scanSource
        r.mode = color == .gray || color == .blackAndWhite ? .gray : .color
        r.dpi = resolutions.contains(dpi) ? dpi : resolutions.last!
        let area = region
        r.x = Int(area.minX); r.y = Int(area.minY)
        r.width = Int(area.width); r.height = Int(area.height)
        r.calibrateEveryScan = calibrateEveryScan
        return r
    }

    var effectiveProcessing: ProcessingOptions {
        var p = processing
        p.outputColor = color
        // Page corners on the glass become corners within the scanned area.
        if let quad = activeQuad, p.autoCrop != .separateItems {
            let area = region
            p.cropQuad = quad.mapped { CGPoint(x: ($0.x - area.minX) / area.width, y: ($0.y - area.minY) / area.height) }
        }
        return p
    }

    /// `baseName` with {date} and {time} filled in.
    func fileName(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        var name = baseName.replacingOccurrences(of: "{date}", with: f.string(from: date))
        f.dateFormat = "HH.mm.ss"
        name = name.replacingOccurrences(of: "{time}", with: f.string(from: date))
        name = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Scan" : name
    }

    static var storageKey: String {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FANON_SNAPSHOT"] != nil { return "ScanSettings.snapshot" }
        #endif
        return "ScanSettings.v1"
    }

    static func load() -> ScanSettings {
        // Fall back to settings saved before the app was renamed from IJScan.
        guard let data = UserDefaults.standard.data(forKey: storageKey)
                ?? UserDefaults(suiteName: "io.github.ijscan")?.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(ScanSettings.self, from: data) else { return ScanSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }
}

/// One-click starting points for common jobs, like the profiles in ScanSnap Home or Epson ScanSmart.
enum ScanPreset: String, CaseIterable, Identifiable {
    case document, book, magazine, photo, multiplePhotos, fadedPhoto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .document: return "Document"
        case .book: return "Book Pages"
        case .magazine: return "Magazine or Brochure"
        case .photo: return "Photo"
        case .multiplePhotos: return "Several Photos at Once"
        case .fadedPhoto: return "Old or Faded Photo"
        }
    }
    var symbol: String {
        switch self {
        case .document: return "doc.text"
        case .book: return "book"
        case .magazine: return "newspaper"
        case .photo: return "photo"
        case .multiplePhotos: return "photo.on.rectangle.angled"
        case .fadedPhoto: return "wand.and.stars"
        }
    }

    func apply(to s: inout ScanSettings) {
        var p = ProcessingOptions()
        p.rotateBackSides = s.processing.rotateBackSides
        switch self {
        case .document:
            s.color = .auto; s.dpi = 300
            p.autoCrop = .document; p.autoRotate = true; p.reduceShowThrough = true; p.unsharpMask = true
            p.skipBlankPages = true
            s.format = .pdf; s.searchablePDF = true
        case .book:
            s.source = .flatbed; s.color = .auto; s.dpi = 300
            p.autoCrop = .straighten; p.autoRotate = true; p.gutterCorrection = true; p.flattenCurvedPages = true
            p.splitFacingPages = true; p.reduceShowThrough = true
            s.format = .pdf; s.searchablePDF = true; s.collectPages = true
        case .magazine:
            s.color = .color; s.dpi = 300
            p.autoCrop = .document; p.descreen = true; p.autoRotate = true
            s.format = .pdf; s.searchablePDF = true
        case .photo:
            s.source = .flatbed; s.color = .color; s.dpi = 600
            p.autoCrop = .document; p.reduceDust = .low
            s.format = .jpeg
        case .multiplePhotos:
            s.source = .flatbed; s.color = .color; s.dpi = 600
            p.autoCrop = .separateItems; p.reduceDust = .low
            s.format = .jpeg
        case .fadedPhoto:
            s.source = .flatbed; s.color = .color; s.dpi = 600
            p.autoCrop = .document; p.fadingCorrection = .medium; p.reduceDust = .medium; p.grainCorrection = .low
            s.format = .jpeg
        }
        s.processing = p
        if s.source == .flatbed {
            if s.paper != .selection { s.paper = .fullGlass }
        } else if !PaperSize.available(for: s.source).contains(s.paper) {
            s.paper = .letter
        }
        if !s.resolutions.contains(s.dpi) { s.dpi = s.resolutions.last! }
    }

    /// The preset these settings match, if any.
    static func matching(_ s: ScanSettings) -> ScanPreset? {
        allCases.first { preset in
            var copy = s
            preset.apply(to: &copy)
            return copy.processing == s.processing && copy.color == s.color && copy.dpi == s.dpi && copy.format == s.format
        }
    }
}
