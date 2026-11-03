import AppKit
import ImageIO
import CoreImage
import PixmaKit
import ESCLKit
import ScanProcessing

/// A scanned page waiting in the tray to be saved.
struct TrayPage: Identifiable {
    let id = UUID()
    var image: ProcessedImage
    var thumbnail: NSImage

    init(_ image: ProcessedImage) {
        self.image = image
        thumbnail = TrayPage.thumbnail(image.image)
    }

    static func thumbnail(_ cg: CGImage) -> NSImage {
        let scale = min(1, 240 / Double(max(cg.width, cg.height)))
        let size = NSSize(width: Double(cg.width) * scale, height: Double(cg.height) * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }
}

/// Owns the scanner connection and runs previews and scans off the main thread.
@MainActor
final class ScanController: ObservableObject {
    enum ScannerState: Equatable {
        case searching
        case ready(ScannerInfo)
        case notFound
    }

    @Published var settings = ScanSettings.load() {
        didSet {
            if settings != oldValue {
                settings.save()
                if settings.processing.toneOnly != oldValue.processing.toneOnly || settings.color != oldValue.color
                    || settings.previewCorrections != oldValue.previewCorrections {
                    refreshPreviewImage()
                }
                if settings.processing.autoCrop != oldValue.processing.autoCrop { autoDetectAfterPreview() }
                if settings.scannerAddress != oldValue.scannerAddress { findScanner() }
            }
        }
    }
    @Published private(set) var scannerState: ScannerState = .searching
    @Published private(set) var isBusy = false
    @Published private(set) var progress: Double?
    @Published private(set) var status = ""
    @Published private(set) var previewImage: NSImage?
    @Published var errorMessage: String?
    @Published private(set) var lastSaved: [URL] = []
    /// Photos found on the glass when "Detect Separate Items" is on (normalised to the glass), for the preview.
    @Published private(set) var detectedItems: [Quad] = []
    @Published var tray: [TrayPage] = []

    /// Raw 75 dpi preview of the whole glass, kept so corrections can be re-applied live.
    private var previewPage: ScannedPage?
    private var activeScanner: PixmaScanner?
    private var previewGeneration = 0
    private let work = DispatchQueue(label: "fanon.app.work", qos: .userInitiated)

    /// The glass in 1/300 inch.
    static let glass = CGSize(width: ScannerModel.mx920.maxWidth300, height: ScannerModel.mx920.maxFlatbedHeight300)

    init() {
        findScanner()
    }

    var scannerInfo: ScannerInfo? {
        if case .ready(let info) = scannerState { return info }
        return nil
    }

    var hasPreview: Bool { previewPage != nil }

    func findScanner() {
        scannerState = .searching
        let fixed = settings.scannerAddress.trimmingCharacters(in: .whitespaces)
        work.async {
            let found = ScannerLocator.locate(fixedHost: fixed.isEmpty ? nil : fixed)
            DispatchQueue.main.async {
                self.scannerState = found.map { .ready($0) } ?? .notFound
            }
        }
    }

    func apply(_ preset: ScanPreset) {
        var s = settings
        preset.apply(to: &s)
        settings = s
        status = "\(preset.title) settings"
    }

    // MARK: - Preview

    func preview() {
        guard let info = scannerInfo, !isBusy else { return }
        var request = ScanRequest()
        request.source = .flatbed
        request.mode = .color
        request.dpi = 75
        request.calibrateEveryScan = settings.calibrateEveryScan
        run(title: "Previewing", host: info.host) { scanner, report in
            var result: ScannedPage?
            try scanner.scan(request, progress: { _, f in report(f, nil) }) { page in
                result = page
                return false
            }
            return result
        } completion: { [weak self] (page: ScannedPage?) in
            guard let self, let page else { return }
            previewPage = page
            refreshPreviewImage()
            autoDetectAfterPreview(fresh: true)
        }
    }

    func refreshPreviewImage() {
        guard let page = previewPage else { previewImage = nil; return }
        previewGeneration += 1
        let generation = previewGeneration
        // Geometry changes would misalign the selection overlay, so preview tone/colour only.
        let options = settings.effectiveProcessing.toneOnly
        let apply = settings.previewCorrections
        work.async {
            let cg: CGImage?
            if apply, let processed = try? ImageProcessor.shared.process(page, options: options).first {
                cg = processed.image
            } else {
                cg = ImageEncoder.cgImage(page)
            }
            DispatchQueue.main.async {
                guard generation == self.previewGeneration, let cg else { return }
                self.previewImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }

    /// After a new preview (or a change of Auto Selection), find the page or photos automatically.
    private func autoDetectAfterPreview(fresh: Bool = false) {
        detectedItems = []
        guard previewPage != nil else { return }
        switch settings.processing.autoCrop {
        case .document where fresh || settings.paper != .selection: detectDocument()
        case .separateItems: detectItems()
        default: break
        }
    }

    /// "Detect Document": finds the page on the preview and selects exactly its corners.
    func detectDocument() {
        guard let page = previewPage, let cg = ImageEncoder.cgImage(page) else { return }
        work.async {
            let quad = ImageProcessor.shared.detectDocument(CIImage(cgImage: cg), dpi: page.dpi)
            DispatchQueue.main.async {
                guard let quad else {
                    self.status = "Couldn't find a page on the glass. Drag to select the area instead."
                    return
                }
                let glass = Self.glass
                self.setDocumentQuad(quad.mapped { CGPoint(x: $0.x * glass.width, y: $0.y * glass.height) })
                self.status = "Page found. Drag the corners to adjust."
            }
        }
    }

    private func detectItems() {
        guard let page = previewPage, let cg = ImageEncoder.cgImage(page) else { return }
        work.async {
            let items = ImageProcessor.shared.detectItems(CIImage(cgImage: cg), dpi: page.dpi)
            DispatchQueue.main.async {
                self.detectedItems = items
                self.status = items.isEmpty ? "No separate items found." : "Found \(items.count) item\(items.count == 1 ? "" : "s")."
            }
        }
    }

    /// Selects a page by its corners (glass coordinates, 1/300 inch); the scan area becomes its bounding box
    /// plus a small margin.
    func setDocumentQuad(_ quad: Quad) {
        let glass = Self.glass
        let clamped = quad.mapped { CGPoint(x: min(max(0, $0.x), glass.width), y: min(max(0, $0.y), glass.height)) }
        var s = settings
        s.documentQuad = clamped
        s.selection = clamped.boundingBox.insetBy(dx: -24, dy: -24)
            .intersection(CGRect(origin: .zero, size: glass)).integral
        s.paper = .selection
        settings = s
    }

    func clearDocumentQuad() {
        settings.documentQuad = nil
    }

    // MARK: - Scan

    func scan() {
        guard let info = scannerInfo, !isBusy else { return }
        let settings = self.settings
        let request = settings.scanRequest()
        let processing = settings.effectiveProcessing
        let collect = settings.collectPages
        run(title: "Scanning", host: info.host) { scanner, report in
            var images: [ProcessedImage] = []
            var pages = 0
            try scanner.scan(request, progress: { page, f in report(f, page + 1) }) { page in
                let isBack = request.source == .adfDuplex && pages % 2 == 1
                images += try ImageProcessor.shared.process(page, options: processing, isBackSide: isBack)
                pages += 1
                return true
            }
            report(1, nil)
            if collect { return (images, [URL]()) }
            let ocr = settings.format == .pdf && settings.searchablePDF
            if !images.isEmpty { DispatchQueue.main.async { self.status = ocr ? "Recognizing text…" : "Saving…" } }
            return (images, try Self.save(images, settings: settings))
        } completion: { [weak self] (result: ([ProcessedImage], [URL])) in
            guard let self else { return }
            let (images, urls) = result
            if images.isEmpty {
                status = "Nothing saved: every page was blank."
            } else if collect {
                tray += images.map(TrayPage.init)
                status = "\(tray.count) page\(tray.count == 1 ? "" : "s") in the tray. Scan more, or Save."
            } else {
                finishedSaving(urls, settings: settings)
            }
        }
    }

    func cancel() {
        activeScanner?.cancel()
        status = "Cancelling…"
    }

    // MARK: - Tray

    func saveTray() {
        guard !tray.isEmpty, !isBusy else { return }
        let images = tray.map(\.image)
        let settings = self.settings
        isBusy = true
        status = settings.format == .pdf && settings.searchablePDF ? "Recognizing text…" : "Saving…"
        work.async {
            let result = Result { try Self.save(images, settings: settings) }
            DispatchQueue.main.async {
                self.isBusy = false
                switch result {
                case .success(let urls):
                    self.tray = []
                    self.finishedSaving(urls, settings: settings)
                case .failure(let error):
                    self.status = ""
                    self.errorMessage = "\(error)"
                }
            }
        }
    }

    func rotateTrayPage(_ id: UUID, degrees: Int) {
        guard let i = tray.firstIndex(where: { $0.id == id }) else { return }
        tray[i] = TrayPage(ImageProcessor.shared.rotated(tray[i].image, degrees: degrees))
    }

    func moveTrayPage(_ id: UUID, by offset: Int) {
        guard let i = tray.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(0, i + offset), tray.count - 1)
        guard i != j else { return }
        tray.swapAt(i, j)
    }

    func removeTrayPage(_ id: UUID) {
        tray.removeAll { $0.id == id }
    }

    // MARK: - Saving

    private func finishedSaving(_ urls: [URL], settings: ScanSettings) {
        lastSaved = urls
        status = urls.count == 1 ? "Saved \(urls[0].lastPathComponent)" : "Saved \(urls.count) files"
        if settings.openAfterScan, !urls.isEmpty {
            urls.forEach { NSWorkspace.shared.open($0) }
        }
    }

    nonisolated private static func save(_ images: [ProcessedImage], settings: ScanSettings) throws -> [URL] {
        guard !images.isEmpty else { return [] }
        let folder = URL(fileURLWithPath: settings.folderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = settings.format
        let name = settings.fileName()
        let quality = settings.compression.jpegQuality
        if format.isMultiPage {
            let url = uniqueURL(folder, name, format.fileExtension)
            try DocumentWriter.write(images, format: format, to: url, searchable: format == .pdf && settings.searchablePDF,
                                     jpegQuality: quality)
            return [url]
        }
        return try images.map { image in
            let url = uniqueURL(folder, name, format.fileExtension)
            try DocumentWriter.write([image], format: format, to: url, jpegQuality: quality)
            return url
        }
    }

    /// "Scan.pdf", then "Scan 2.pdf", "Scan 3.pdf", …
    nonisolated private static func uniqueURL(_ folder: URL, _ name: String, _ ext: String) -> URL {
        var url = folder.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).\(ext)")
            n += 1
        }
        return url
    }

    #if DEBUG
    /// Uses an image of the whole glass at 75 dpi as the preview (see `DebugSnapshot`).
    func loadPreview(from url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        var request = ScanRequest()
        request.dpi = 75
        guard let geometry = try? PageGeometry.make(request, model: .mx920) else { return }
        let w = geometry.width, h = geometry.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rgb = Data(count: w * h * 3)
        for i in 0..<(w * h) { for c in 0..<3 { rgb[i * 3 + c] = rgba[i * 4 + c] } }
        previewPage = ScannedPage(geometry: geometry, pixels: rgb)
        refreshPreviewImage()
        autoDetectAfterPreview(fresh: true)
    }

    func fillTrayFromPreview(count: Int) {
        guard let page = previewPage,
              let image = try? ImageProcessor.shared.process(page, options: settings.effectiveProcessing).first else { return }
        tray = (0..<count).map { _ in TrayPage(image) }
    }
    #endif

    // MARK: - Plumbing

    /// Runs device work on the background queue, reporting progress, then hands the result back.
    private func run<T>(title: String, host: String,
                        _ body: @escaping (PixmaScanner, @escaping (Double, Int?) -> Void) throws -> T,
                        completion: @escaping (T) -> Void) {
        isBusy = true
        progress = 0
        status = "\(title)…"
        errorMessage = nil
        work.async {
            let result: Result<T, Error>
            do {
                let scanner = try PixmaScanner(host: host)
                DispatchQueue.main.async { self.activeScanner = scanner }
                let report: (Double, Int?) -> Void = { fraction, page in
                    DispatchQueue.main.async {
                        self.progress = fraction
                        if let page { self.status = "\(title) page \(page)…" }
                    }
                }
                result = .success(try body(scanner, report))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.progress = nil
                self.activeScanner = nil
                self.status = ""
                switch result {
                case .success(let value): completion(value)
                case .failure(PixmaError.cancelled): self.status = "Cancelled"
                case .failure(let error):
                    self.errorMessage = "\(error)"
                    if case PixmaError.network = error { self.findScanner() }
                    if case PixmaError.timeout = error { self.findScanner() }
                }
            }
        }
    }
}
