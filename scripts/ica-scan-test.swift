// End-to-end check through Apple's own scanner stack (ImageCaptureCore → AirScan/eSCL → bridge).
//
//   swift scripts/ica-scan-test.swift list
//   swift scripts/ica-scan-test.swift scan <output-dir> [dpi] [flatbed|feeder]
import Foundation
import ImageCaptureCore

final class Tester: NSObject, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    let browser = ICDeviceBrowser()
    let mode: String
    let outDir: URL
    let dpi: Int
    let useFeeder: Bool
    var device: ICScannerDevice?

    init(mode: String, outDir: URL, dpi: Int, useFeeder: Bool) {
        self.mode = mode
        self.outDir = outDir
        self.dpi = dpi
        self.useFeeder = useFeeder
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue | ICDeviceLocationTypeMask.shared.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
        browser.start()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        print("found: \(device.name ?? "?") [\(device.transportType ?? "?")] uuid=\(device.uuidString ?? "?")")
        guard mode == "scan" || mode == "features", self.device == nil, let scanner = device as? ICScannerDevice,
              (device.name ?? "").contains("(Fanon)") else { return }
        self.device = scanner
        scanner.delegate = self
        scanner.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    func didRemove(_ device: ICDevice) {}

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { fail("open session: \(error)") }
        print("session open")
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        guard let scanner = device as? ICScannerDevice else { return }
        print("ready; units: \(scanner.availableFunctionalUnitTypes.map { $0.intValue })")
        let unit: ICScannerFunctionalUnitType = useFeeder ? .documentFeeder : .flatbed
        scanner.requestSelect(unit)
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    func scannerDevice(_ scanner: ICScannerDevice, didSelect unit: ICScannerFunctionalUnit, error: Error?) {
        if let error { fail("select unit: \(error)") }
        print("selected \(unit.type.rawValue); resolutions \(Array(unit.supportedResolutions))")
        if mode == "features", unit.supportedResolutions.count > 0 {
            for f in unit.vendorFeatures ?? [] {
                var extra = ""
                if let e = f as? ICScannerFeatureEnumeration { extra = "values=\(e.values) names=\(e.menuItemLabels)" }
                if let r = f as? ICScannerFeatureRange { extra = "range=\(r.minValue)...\(r.maxValue) current=\(r.currentValue)" }
                if let b = f as? ICScannerFeatureBoolean { extra = "bool=\(b.value)" }
                print("  feature \(f.internalName ?? "?") '\(f.humanReadableName ?? "")' type=\(f.type.rawValue) \(extra)")
            }
            print("  vendorFeatures count: \(unit.vendorFeatures?.count ?? 0)")
            exit(0)
        }
        if mode == "features" { return }
        unit.resolution = dpi
        unit.pixelDataType = .RGB
        unit.bitDepth = .depth8Bits
        unit.measurementUnit = .inches
        if let fb = unit as? ICScannerFunctionalUnitFlatbed {
            fb.scanArea = NSRect(x: 0, y: 0, width: 4, height: 3)
        }
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.documentType = .typeUSLetter
        }
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = outDir
        scanner.documentName = "ica-test"
        scanner.documentUTI = "public.jpeg"
        print("requesting scan at \(dpi) dpi…")
        scanner.requestScan()
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        print("scanned to \(url.path)")
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        if let error { fail("scan: \(error)") }
        print("scan complete")
        exit(0)
    }

    func fail(_ msg: String) -> Never {
        print("FAILED: \(msg)")
        exit(1)
    }
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "list"
let out = URL(fileURLWithPath: args.count > 2 ? args[2] : FileManager.default.currentDirectoryPath)
let tester = Tester(mode: mode, outDir: out, dpi: args.count > 3 ? Int(args[3]) ?? 150 : 150,
                    useFeeder: args.count > 4 && args[4] == "feeder")
DispatchQueue.main.asyncAfter(deadline: .now() + (mode == "list" ? 8 : 240)) {
    print(mode == "list" ? "done listing" : "FAILED: timed out")
    exit(mode == "list" ? 0 : 1)
}
RunLoop.main.run()
