import Foundation
import CoreImage
import ImageIO
import PixmaKit
import ESCLKit
import ScanProcessing

let usage = """
usage: fanon <command> [options]

commands:
  discover                      find Canon scanners on the local network
  status   --host <ip>          show the scanner identity and ADF state
  scan     --host <ip> -o <file> [--dpi 300] [--mode color|gray]
           [--source flatbed|adf|duplex] [--x 0 --y 0 --width W --height H (1/300 in)]
           [--fix <list>]       scan to .jpg, .png, .pdf or .tiff
  process  -i <image> -o <file> [--dpi N] [--fix <list>]
                                apply corrections to an existing image
  detect   -i <image> [--dpi N] print where the page (or photos) are on an image
  serve    [--host <ip>] [--port 8090]
                                run the AirScan (eSCL) bridge in the foreground

  --fix takes a comma-separated list of: unsharp, descreen, showthrough, gutter,
        dust=low|medium|high, fading=…, grain=…, auto, straighten, crop, items,
        rotate=90|180|270|auto, flipback (rotate duplex back sides), flatten (curved
        book pages), split (facing pages), skipblank, gray, bw, autocolor,
        ocr (searchable PDF), calibrate, quality=0.1…1 (JPEG/PDF compression)

options:
  -v, --verbose                 log protocol traffic
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fanon: \(message)\n".utf8))
    exit(1)
}

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

var options: [String: String] = [:]
var i = 0
while i < args.count {
    let a = args[i]
    if a == "-v" || a == "--verbose" {
        PixmaLog.verbose = true
    } else if a.hasPrefix("-") {
        guard i + 1 < args.count else { fail("missing value for \(a)") }
        options[a.trimmingCharacters(in: CharacterSet(charactersIn: "-"))] = args[i + 1]
        i += 1
    } else {
        fail("unexpected argument \(a)")
    }
    i += 1
}

func resolveHost() -> String {
    if let host = options["host"] { return host }
    guard let info = ScannerLocator.locate(fixedHost: nil) else { fail("no scanner found; pass --host <ip>") }
    print("Using \(info.model) at \(info.host)")
    return info.host
}

func intOption(_ name: String) -> Int? {
    guard let s = options[name] else { return nil }
    guard let v = Int(s) else { fail("--\(name) expects a number") }
    return v
}

/// `--fix unsharp,descreen,showthrough,dust=medium,fading=high,grain=low,gutter,auto,crop,items,rotate=90,gray,bw,ocr,calibrate`
let fixes: [String: String] = Dictionary((options["fix"] ?? "").split(separator: ",").map { item -> (String, String) in
    let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
    return (kv[0].lowercased(), kv.count > 1 ? kv[1].lowercased() : "medium")
}, uniquingKeysWith: { $1 })

func processingOptions() -> ProcessingOptions {
    var o = ProcessingOptions()
    func level(_ key: String) -> ProcessingOptions.Level {
        guard let v = fixes[key] else { return .none }
        guard let l = ProcessingOptions.Level(rawValue: v) else { fail("--fix \(key)= expects low, medium or high") }
        return l
    }
    o.unsharpMask = fixes["unsharp"] != nil
    o.descreen = fixes["descreen"] != nil
    o.reduceShowThrough = fixes["showthrough"] != nil
    o.gutterCorrection = fixes["gutter"] != nil
    o.autoAdjust = fixes["auto"] != nil
    o.reduceDust = level("dust")
    o.fadingCorrection = level("fading")
    o.grainCorrection = level("grain")
    o.autoCrop = fixes["items"] != nil ? .separateItems : fixes["crop"] != nil ? .document
        : fixes["straighten"] != nil ? .straighten : .none
    o.autoRotate = fixes["rotate"] == "auto"
    o.rotation = Int(fixes["rotate"] ?? "0") ?? 0
    o.rotateBackSides = fixes["flipback"] != nil
    o.flattenCurvedPages = fixes["flatten"] != nil
    o.splitFacingPages = fixes["split"] != nil
    o.skipBlankPages = fixes["skipblank"] != nil
    o.outputColor = fixes["bw"] != nil ? .blackAndWhite : fixes["gray"] != nil ? .gray
        : fixes["autocolor"] != nil ? .auto : .color
    return o
}

let jpegQuality = Double(fixes["quality"] ?? "") ?? 0.9

func outputTarget(_ path: String) -> (URL, OutputFormat) {
    let url = URL(fileURLWithPath: path)
    let ext = url.pathExtension.lowercased()
    let format: OutputFormat? = ["jpg": .jpeg, "jpeg": .jpeg, "png": .png, "tif": .tiff, "tiff": .tiff, "pdf": .pdf][ext]
    guard let format else { fail("unsupported output type .\(ext)") }
    return (url, format)
}

do {
    switch command {
    case "discover":
        if let info = ScannerLocator.locate(fixedHost: nil) {
            print("\(info.model) at \(info.host) (MAC \(info.mac))")
        } else {
            print("No Canon MX920 series scanner found.")
        }

    case "status":
        let host = resolveHost()
        let scanner = try PixmaScanner(host: host)
        print("Address:  \(scanner.connection.resolvedAddress)")
        print("MAC:      \(try scanner.connection.discover())")
        let id = try scanner.connection.identity()
        print("Model:    \(IEEE1284.model(from: id) ?? "unknown")")
        print("Identity: \(id)")
        let status = try scanner.fetchStatus()
        print("ADF:      \(status.adfLoaded ? "paper loaded" : "empty")")
        print("Raw:      \(status.raw.map { String(format: "%02x", $0) }.joined(separator: " "))")

    case "detect":
        guard let input = options["i"] ?? options["input"] else { fail("detect needs -i <image>") }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read \(input)") }
        let dpi = intOption("dpi") ?? 75
        let ci = CIImage(cgImage: image)
        func describe(_ q: Quad) -> String {
            q.points.map { String(format: "(%.2f, %.2f)", $0.x * CGFloat(image.width) / CGFloat(dpi),
                                  $0.y * CGFloat(image.height) / CGFloat(dpi)) }.joined(separator: " ")
                + String(format: "  tilt %.2f°", atan2(Double((q.topRight.y - q.topLeft.y) * CGFloat(image.height)),
                                                       Double((q.topRight.x - q.topLeft.x) * CGFloat(image.width))) * 180 / .pi)
        }
        if let q = ImageProcessor.shared.detectDocument(ci, dpi: dpi) { print("Document (in): \(describe(q))") } else { print("No document found") }
        for (n, q) in ImageProcessor.shared.detectItems(ci, dpi: dpi).enumerated() { print("Item \(n + 1) (in): \(describe(q))") }
        if let skew = ImageProcessor.shared.textSkew(ci, dpi: dpi) { print(String(format: "Text skew: %.2f° clockwise", skew)) }

    case "process":
        guard let input = options["i"] ?? options["input"], let output = options["o"] ?? options["output"] else {
            fail("process needs -i <image> -o <file>")
        }
        let (url, format) = outputTarget(output)
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read \(input)") }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = intOption("dpi") ?? (props?[kCGImagePropertyDPIWidth] as? Int) ?? 300
        let start = Date()
        let results = try ImageProcessor.shared.process(CIImage(cgImage: image), dpi: dpi, options: processingOptions())
        try DocumentWriter.write(results, format: format, to: url, searchable: fixes["ocr"] != nil, jpegQuality: jpegQuality)
        print(String(format: "Wrote \(url.path) (\(results.count) image(s)) in %.1f s", Date().timeIntervalSince(start)))

    case "scan":
        guard let output = options["o"] ?? options["output"] else { fail("scan needs -o <file>") }
        let (url, format) = outputTarget(output)
        var request = ScanRequest()
        request.calibrateEveryScan = fixes["calibrate"] != nil
        request.dpi = intOption("dpi") ?? 300
        switch options["mode"] ?? "color" {
        case "color": request.mode = .color
        case "gray", "grey", "grayscale": request.mode = .gray
        case let m: fail("unknown mode \(m)")
        }
        switch options["source"] ?? "flatbed" {
        case "flatbed": request.source = .flatbed
        case "adf": request.source = .adf
        case "duplex": request.source = .adfDuplex
        case let s: fail("unknown source \(s)")
        }
        if request.source.isADF { request.height = ScannerModel.mx920.maxADFHeight300 }
        request.x = intOption("x") ?? 0
        request.y = intOption("y") ?? 0
        request.width = intOption("width") ?? request.width
        request.height = intOption("height") ?? request.height

        let scanner = try PixmaScanner(host: resolveHost())
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler { print("\nCancelling…"); scanner.cancel() }
        sigint.resume()

        let start = Date()
        var processing = processingOptions()
        if request.mode == .gray, processing.outputColor == .color { processing.outputColor = .gray }
        var images: [ProcessedImage] = []
        var pageCount = 0
        try scanner.scan(request) { page in
            print("Page \(pageCount + 1): \(page.width)×\(page.height) px at \(page.dpi) dpi")
            let isBack = request.source == .adfDuplex && pageCount % 2 == 1
            images += try ImageProcessor.shared.process(page, options: processing, isBackSide: isBack)
            pageCount += 1
            return true
        }
        if !format.isMultiPage, images.count > 1 {
            for (n, image) in images.enumerated() {
                let pageURL = url.deletingPathExtension().appendingPathExtension("\(n + 1).\(format.fileExtension)")
                try DocumentWriter.write([image], format: format, to: pageURL, jpegQuality: jpegQuality)
                print("Wrote \(pageURL.path)")
            }
        } else {
            try DocumentWriter.write(images, format: format, to: url, searchable: fixes["ocr"] != nil, jpegQuality: jpegQuality)
            print("Wrote \(url.path)")
        }
        print(String(format: "Done in %.1f s", Date().timeIntervalSince(start)))

    case "serve":
        let port = UInt16(intOption("port") ?? 8090)
        let bridge = ScanBridge(fixedHost: options["host"], port: port)
        bridge.onLog = { print($0) }
        try bridge.start()
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { bridge.stop(); exit(0) }
        sigint.resume()
        dispatchMain()

    case "help", "-h", "--help":
        print(usage)

    default:
        fail("unknown command \(command)\n\n\(usage)")
    }
} catch {
    fail("\(error)")
}
