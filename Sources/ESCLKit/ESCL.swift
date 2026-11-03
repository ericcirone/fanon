import Foundation
import PixmaKit

/// eSCL (Mopria / Apple AirScan) document builders and parsers.
public enum ESCL {
    public static let version = "2.63"
    static let namespaces = #"xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm""#

    /// Resolutions offered to clients. 2400 dpi is left out: a full page would need ~1.7 GB of RAM.
    static let platenResolutions = [75, 150, 300, 600, 1200]
    static let feederResolutions = [75, 150, 300, 600]
    public static let documentFormats: [ImageFormat] = [.jpeg, .pdf, .png]

    public struct Device {
        public var makeAndModel: String
        public var serial: String
        public var uuid: String
        public var baseURL: String
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func inputCaps(maxWidth: Int, maxHeight: Int, resolutions: [Int], maxDPI: Int) -> String {
        let modes = ["RGB24", "Grayscale8"].map { "<scan:ColorMode>\($0)</scan:ColorMode>" }.joined()
        let formats = documentFormats.map {
            "<pwg:DocumentFormat>\($0.rawValue)</pwg:DocumentFormat><scan:DocumentFormatExt>\($0.rawValue)</scan:DocumentFormatExt>"
        }.joined()
        let res = resolutions.map {
            "<scan:DiscreteResolution><scan:XResolution>\($0)</scan:XResolution><scan:YResolution>\($0)</scan:YResolution></scan:DiscreteResolution>"
        }.joined()
        let intents = ["Document", "TextAndGraphic", "Photo", "Preview"].map { "<scan:Intent>\($0)</scan:Intent>" }.joined()
        return """
        <scan:MinWidth>16</scan:MinWidth><scan:MaxWidth>\(maxWidth)</scan:MaxWidth>\
        <scan:MinHeight>16</scan:MinHeight><scan:MaxHeight>\(maxHeight)</scan:MaxHeight>\
        <scan:MaxScanRegions>1</scan:MaxScanRegions>\
        <scan:SettingProfiles><scan:SettingProfile>\
        <scan:ColorModes>\(modes)</scan:ColorModes>\
        <scan:DocumentFormats>\(formats)</scan:DocumentFormats>\
        <scan:SupportedResolutions><scan:DiscreteResolutions>\(res)</scan:DiscreteResolutions></scan:SupportedResolutions>\
        <scan:ColorSpaces><scan:ColorSpace>sRGB</scan:ColorSpace></scan:ColorSpaces>\
        </scan:SettingProfile></scan:SettingProfiles>\
        <scan:SupportedIntents>\(intents)</scan:SupportedIntents>\
        <scan:MaxOpticalXResolution>\(maxDPI)</scan:MaxOpticalXResolution>\
        <scan:MaxOpticalYResolution>\(maxDPI)</scan:MaxOpticalYResolution>\
        <scan:RiskyLeftMargin>0</scan:RiskyLeftMargin><scan:RiskyRightMargin>0</scan:RiskyRightMargin>\
        <scan:RiskyTopMargin>0</scan:RiskyTopMargin><scan:RiskyBottomMargin>0</scan:RiskyBottomMargin>
        """
    }

    public static func capabilities(_ d: Device, model: ScannerModel) -> String {
        let platen = inputCaps(maxWidth: model.maxWidth300, maxHeight: model.maxFlatbedHeight300,
                               resolutions: platenResolutions, maxDPI: model.maxFlatbedDPI)
        let feeder = inputCaps(maxWidth: model.maxWidth300, maxHeight: model.maxADFHeight300,
                               resolutions: feederResolutions, maxDPI: model.maxADFDPI)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerCapabilities \(namespaces)>\
        <pwg:Version>\(version)</pwg:Version>\
        <pwg:MakeAndModel>\(escape(d.makeAndModel))</pwg:MakeAndModel>\
        <pwg:SerialNumber>\(escape(d.serial))</pwg:SerialNumber>\
        <scan:UUID>\(d.uuid)</scan:UUID>\
        <scan:AdminURI>\(d.baseURL)/</scan:AdminURI>\
        <scan:IconURI>\(d.baseURL)/icon.png</scan:IconURI>\
        <scan:Platen><scan:PlatenInputCaps>\(platen)</scan:PlatenInputCaps></scan:Platen>\
        <scan:Adf>\
        <scan:AdfSimplexInputCaps>\(feeder)</scan:AdfSimplexInputCaps>\
        <scan:AdfDuplexInputCaps>\(feeder)</scan:AdfDuplexInputCaps>\
        <scan:FeederCapacity>35</scan:FeederCapacity>\
        <scan:AdfOptions><scan:AdfOption>DetectPaperLoaded</scan:AdfOption><scan:AdfOption>Duplex</scan:AdfOption></scan:AdfOptions>\
        </scan:Adf>\
        </scan:ScannerCapabilities>
        """
    }

    public struct JobInfo {
        public var uuid: String
        public var age: Int
        public var imagesCompleted: Int
        public var imagesToTransfer: Int
        public var state: String          // Pending, Processing, Completed, Canceled, Aborted
        public var reason: String         // e.g. JobCompletedSuccessfully
    }

    public static func status(state: String, adfState: String?, jobs: [JobInfo]) -> String {
        let jobXML = jobs.map {
            """
            <scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/\($0.uuid)</pwg:JobUri><pwg:JobUuid>\($0.uuid)</pwg:JobUuid>\
            <scan:Age>\($0.age)</scan:Age><pwg:ImagesCompleted>\($0.imagesCompleted)</pwg:ImagesCompleted>\
            <pwg:ImagesToTransfer>\($0.imagesToTransfer)</pwg:ImagesToTransfer><pwg:JobState>\($0.state)</pwg:JobState>\
            <pwg:JobStateReasons><pwg:JobStateReason>\($0.reason)</pwg:JobStateReason></pwg:JobStateReasons></scan:JobInfo>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerStatus \(namespaces)><pwg:Version>\(version)</pwg:Version><pwg:State>\(state)</pwg:State>\
        \(adfState.map { "<scan:AdfState>\($0)</scan:AdfState>" } ?? "")\
        <scan:Jobs>\(jobXML)</scan:Jobs></scan:ScannerStatus>
        """
    }

    public static func imageInfo(jobUUID: String, page: ScannedPage) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanImageInfo \(namespaces)><pwg:JobUri>/eSCL/ScanJobs/\(jobUUID)</pwg:JobUri>\
        <pwg:JobUuid>\(jobUUID)</pwg:JobUuid><scan:ActualWidth>\(page.width)</scan:ActualWidth>\
        <scan:ActualHeight>\(page.height)</scan:ActualHeight>\
        <scan:ActualBytesPerLine>\(page.width * page.channels)</scan:ActualBytesPerLine></scan:ScanImageInfo>
        """
    }

    /// Settings posted by the client to /eSCL/ScanJobs.
    public struct ScanSettings: Equatable {
        public var inputSource = "Platen"
        public var duplex = false
        public var colorMode = "RGB24"
        public var format: ImageFormat = .jpeg
        public var xResolution = 300
        public var yResolution = 300
        public var x = 0
        public var y = 0
        public var width: Int?
        public var height: Int?
        public var intent: String?

        public func scanRequest(model: ScannerModel) -> ScanRequest {
            var r = ScanRequest()
            let feeder = inputSource.lowercased() == "feeder"
            r.source = feeder ? (duplex ? .adfDuplex : .adf) : .flatbed
            r.mode = colorMode.lowercased().hasPrefix("grayscale") || colorMode.lowercased().hasPrefix("blackandwhite") ? .gray : .color
            // Pick the closest native resolution at or above what was asked for.
            let allowed = feeder ? ESCL.feederResolutions : ESCL.platenResolutions
            let wanted = max(xResolution, yResolution)
            r.dpi = allowed.first { $0 >= wanted } ?? allowed.last!
            r.x = x
            r.y = y
            r.width = width ?? model.maxWidth300
            r.height = height ?? (feeder ? model.maxADFHeight300 : model.maxFlatbedHeight300)
            return r
        }
    }

    public static func parseSettings(_ data: Data) -> ScanSettings? {
        let parser = SettingsParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return nil }
        return parser.settings
    }

    private final class SettingsParser: NSObject, XMLParserDelegate {
        var settings = ScanSettings()
        private var text = ""
        private var formatExt: ImageFormat?
        private var format: ImageFormat?
        private var inRegion = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if local(name) == "ScanRegion" { inRegion = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch local(name) {
            case "InputSource": settings.inputSource = value
            case "Duplex": settings.duplex = value.lowercased() == "true" || value == "1"
            case "ColorMode": settings.colorMode = value
            case "DocumentFormatExt": formatExt = ImageFormat(rawValue: value.lowercased())
            case "DocumentFormat": format = ImageFormat(rawValue: value.lowercased())
            case "XResolution": settings.xResolution = Int(value) ?? settings.xResolution
            case "YResolution": settings.yResolution = Int(value) ?? settings.yResolution
            case "XOffset" where inRegion: settings.x = Int(value) ?? 0
            case "YOffset" where inRegion: settings.y = Int(value) ?? 0
            case "Width" where inRegion: settings.width = Int(value)
            case "Height" where inRegion: settings.height = Int(value)
            case "ScanRegion": inRegion = false
            case "Intent": settings.intent = value
            default: break
            }
            text = ""
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            if let f = formatExt ?? format { settings.format = f }
        }

        private func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }
    }
}
