import Foundation

public enum ScanSource: String, CaseIterable, Sendable {
    case flatbed, adf, adfDuplex
    public var isADF: Bool { self != .flatbed }
}

public enum ColorMode: String, CaseIterable, Sendable {
    case color, gray
    public var channels: Int { self == .color ? 3 : 1 }
}

/// A scan request. The region is in 1/300 inch, matching eSCL's ThreeHundredthsOfInches.
public struct ScanRequest: Sendable {
    public var source: ScanSource = .flatbed
    public var mode: ColorMode = .color
    public var dpi: Int = 300
    public var x: Int = 0
    public var y: Int = 0
    public var width: Int = ScannerModel.mx920.maxWidth300
    public var height: Int = ScannerModel.mx920.maxFlatbedHeight300
    public var gamma: Double = 2.2
    /// Recalibrate the sensor for every scan instead of only when the source changes.
    public var calibrateEveryScan = false

    public init() {}
}

/// Static capabilities for a supported model (values from the SANE pixma device table).
public struct ScannerModel: Sendable {
    public let name: String
    public let usbProductID: UInt16
    public let maxFlatbedDPI: Int
    public let maxADFDPI: Int
    /// Widths/heights in 1/75 inch, as the device table stores them.
    let width75: Int
    let flatbedHeight75: Int
    let adfHeight75: Int

    public var maxWidth300: Int { width75 * 4 }
    public var maxFlatbedHeight300: Int { flatbedHeight75 * 4 }
    public var maxADFHeight300: Int { adfHeight75 * 4 }

    public var resolutions: [Int] { [75, 150, 300, 600, 1200, 2400].filter { $0 <= maxFlatbedDPI } }

    /// Canon PIXMA MX920 series (MX922, MX923, MX924, MX925): CIS sensor, duplex ADF.
    public static let mx920 = ScannerModel(name: "Canon PIXMA MX920 series", usbProductID: 0x176b,
                                           maxFlatbedDPI: 2400, maxADFDPI: 600,
                                           width75: 638, flatbedHeight75: 877, adfHeight75: 1050)
}

/// Geometry of one page after the parameters were adjusted to what the device accepts.
public struct PageGeometry: Sendable, Equatable {
    public let dpi: Int
    public let channels: Int
    /// Output image size in pixels.
    public let width: Int
    public let height: Int
    /// Origin in pixels, with `x` aligned down to a multiple of 32 and `xShift` the remainder.
    let x: Int
    let xShift: Int
    let y: Int
    /// Raw line width in pixels as the device delivers it (multiple of 32).
    let rawWidth: Int

    public var bytesPerLine: Int { width * channels }
    var rawBytesPerLine: Int { rawWidth * channels }

    public static func make(_ r: ScanRequest, model: ScannerModel) throws -> PageGeometry {
        let maxDPI = r.source.isADF ? model.maxADFDPI : model.maxFlatbedDPI
        guard model.resolutions.contains(r.dpi) else {
            throw PixmaError.invalidParameter("resolution \(r.dpi) dpi is not supported")
        }
        let dpi = min(r.dpi, maxDPI)
        let maxW300 = model.maxWidth300
        let maxH300 = r.source.isADF ? model.maxADFHeight300 : model.maxFlatbedHeight300

        let x300 = max(0, min(r.x, maxW300 - 16))
        let y300 = max(0, min(r.y, maxH300 - 16))
        let w300 = max(16, min(r.width, maxW300 - x300))
        let h300 = max(16, min(r.height, maxH300 - y300))

        let px = x300 * dpi / 300
        let py = y300 * dpi / 300
        let w = max(1, w300 * dpi / 300)
        let h = max(1, h300 * dpi / 300)
        let shift = px % 32
        let raw = (w + shift + 31) / 32 * 32
        return PageGeometry(dpi: dpi, channels: r.mode.channels, width: w, height: h,
                            x: px - shift, xShift: shift, y: py, rawWidth: raw)
    }
}

/// Status flags reported by the device.
public struct DeviceStatus: Sendable {
    public let raw: [UInt8]
    /// Paper present in the ADF.
    public var adfLoaded: Bool { raw.count > 1 && raw[1] == 0 }
}

/// Driver for the PIXMA "generation 5" scan protocol used by the MX920 series.
///
/// Command packets are `u16be cmd, u8[10] 0, u16be len, data..., checksum`; responses start
/// with an 8-byte header whose first two bytes are the status (0x0606 OK, 0x1414 busy,
/// 0x1515 failed). Gen-4+ devices additionally require a short XML "StartJob"/"ModeShift"
/// dialog before and an "EndJob" message after each session.
public final class PixmaScanner {
    enum Cmd: UInt16 {
        case startSession = 0xdb20
        case gamma = 0xee20
        case status = 0xf320
        case abortSession = 0xef20
        case readImage = 0xd420
        case errorInfo = 0xff20
        case scanParam3 = 0xd820
        case scanStart3 = 0xd920
        case status3 = 0xda20
    }

    static let statusOK: UInt16 = 0x0606
    static let statusBusy: UInt16 = 0x1414
    static let statusFailed: UInt16 = 0x1515
    static let imageBlockSize = 512 * 1024

    static let xmlStartJob = """
    <?xml version="1.0" encoding="utf-8" ?><cmd xmlns:ivec="http://www.canon.com/ns/cmd/2008/07/common/"><ivec:contents><ivec:operation>StartJob</ivec:operation><ivec:param_set servicetype="scan"><ivec:jobID>00000001</ivec:jobID><ivec:bidi>1</ivec:bidi></ivec:param_set></ivec:contents></cmd>
    """
    static let xmlModeShift = """
    <?xml version="1.0" encoding="utf-8" ?><cmd xmlns:ivec="http://www.canon.com/ns/cmd/2008/07/common/" xmlns:vcn="http://www.canon.com/ns/cmd/2008/07/canon/"><ivec:contents><ivec:operation>VendorCmd</ivec:operation><ivec:param_set servicetype="scan"><ivec:jobID>00000001</ivec:jobID><vcn:ijoperation>ModeShift</vcn:ijoperation><vcn:ijmode>1</vcn:ijmode></ivec:param_set></ivec:contents></cmd>
    """
    static let xmlEndJob = """
    <?xml version="1.0" encoding="utf-8" ?><cmd xmlns:ivec="http://www.canon.com/ns/cmd/2008/07/common/"><ivec:contents><ivec:operation>EndJob</ivec:operation><ivec:param_set servicetype="scan"><ivec:jobID>00000001</ivec:jobID></ivec:param_set></ivec:contents></cmd>
    """

    public let model: ScannerModel
    public let connection: BJNPConnection
    private var lastSource: ScanSource?
    private let cancelLock = NSLock()
    private var cancelRequested = false

    public init(host: String, model: ScannerModel = .mx920) throws {
        self.model = model
        self.connection = try BJNPConnection(host: host)
    }

    /// Requests cancellation of the scan in progress; safe to call from any thread.
    public func cancel() {
        cancelLock.lock(); cancelRequested = true; cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelRequested
    }

    // MARK: - Command plumbing

    private func checkStatus(_ response: Data) throws {
        guard response.count >= 8 else { throw PixmaError.protocolError("short response (\(response.count) bytes)") }
        switch response.be16(at: 0) {
        case Self.statusOK: return
        case Self.statusBusy: throw PixmaError.busy
        case Self.statusFailed: throw PixmaError.deviceFailed("command failed (0x1515)")
        case let s: throw PixmaError.protocolError(String(format: "unknown status 0x%04x", s))
        }
    }

    /// Reads one command response. Responses that carry data are longer than the 8-byte header;
    /// a header-only reply signals an error status.
    private func readResponse(expected: Int) throws -> Data {
        var response = Data()
        repeat {
            let chunk = try connection.readChunk()
            if chunk.isEmpty { break }
            response += chunk
        } while response.count < expected && response.count != 8
        return response
    }

    /// Executes a command with optional output data and returns the response data (without header).
    @discardableResult
    private func exec(_ cmd: Cmd, out: Data = Data(), outLength: Int = 0, inLength: Int = 0) throws -> Data {
        let dataOut = max(outLength, out.count)
        var packet = Data(count: 16 + dataOut)
        packet.setBE16(cmd.rawValue, at: 0)
        packet.setBE16(UInt16(dataOut + inLength), at: 14)
        if dataOut > 0 {
            packet.replaceSubrange(16..<(16 + out.count), with: out)
            let sum = packet[16..<(16 + dataOut - 1)].reduce(UInt8(0)) { $0 &+ $1 }
            packet[16 + dataOut - 1] = 0 &- sum
        }
        try connection.write(packet)
        let expected = 8 + inLength
        let response = try readResponse(expected: expected)
        try checkStatus(response)
        if inLength > 0 {
            guard response.count == expected else {
                throw PixmaError.protocolError("\(cmd) returned \(response.count) bytes, expected \(expected)")
            }
            let body = response.dropFirst(8)
            guard body.reduce(UInt8(0), { $0 &+ $1 }) == 0 else {
                throw PixmaError.protocolError("\(cmd) checksum mismatch")
            }
            return Data(body)
        }
        return Data()
    }

    private func xmlDialog(_ xml: String) throws {
        try connection.write(Data(xml.utf8))
        let response = try connection.readChunk()
        let text = String(decoding: response, as: UTF8.self)
        PixmaLog.debug("xml reply: \(text)")
        guard text.range(of: "<ivec:response>OK</ivec:response>", options: .caseInsensitive) != nil else {
            let detail = text.range(of: "<ivec:response_detail>(.*?)</ivec:response_detail>", options: .regularExpression)
                .map { String(text[$0]) } ?? text
            throw PixmaError.deviceFailed("scanner refused job: \(detail)")
        }
    }

    // MARK: - Device commands

    func queryStatus() throws -> DeviceStatus {
        DeviceStatus(raw: [UInt8](try exec(.status, inLength: 16)))
    }

    /// Opens a short job to read the device status (the device only answers inside a job).
    public func fetchStatus() throws -> DeviceStatus {
        try connection.open(jobTitle: "Status")
        defer { connection.close() }
        try xmlDialog(Self.xmlStartJob)
        defer { _ = try? xmlDialog(Self.xmlEndJob) }
        try xmlDialog(Self.xmlModeShift)
        return try queryStatus()
    }

    private func queryStatus3() throws -> [UInt8] {
        [UInt8](try exec(.status3, inLength: 8))
    }

    private func startSession() throws {
        var lastError: Error = PixmaError.busy
        for attempt in 0...10 {
            if isCancelled { throw PixmaError.cancelled }
            do {
                try exec(.startSession)
                return
            } catch PixmaError.busy {
                PixmaLog.debug("scanner busy, retry \(attempt)")
                lastError = PixmaError.busy
                Thread.sleep(forTimeInterval: 1)
            }
        }
        // The device may be stuck in a previous session: abort it and try once more.
        _ = try? exec(.abortSession)
        Thread.sleep(forTimeInterval: 0.5)
        do { try exec(.startSession) } catch { throw lastError }
    }

    private func sendGammaTable(gamma: Double) throws {
        // 1024 little-endian 16-bit entries, preceded by a 4-byte table descriptor.
        var data = Data(count: 1024 * 2 + 8)
        data[0] = 0x10
        data.setBE16(0x0804, at: 2)
        let rGamma = 1.0 / gamma
        for i in 0..<1024 {
            let v = UInt16(65535.0 * pow(Double(i) / 1023.0, rGamma) + 0.5)
            data[4 + 2 * i] = UInt8(v & 0xff)
            data[5 + 2 * i] = UInt8(v >> 8)
        }
        try exec(.gamma, out: data)
    }

    private func sendScanParameters(_ g: PageGeometry, source: ScanSource, calibrate: Bool) throws {
        var d = Data(count: 0x38)
        d[0x00] = source.isADF ? 0x02 : 0x01
        d[0x01] = 0x01
        d[0x02] = 0x01
        if source == .adfDuplex {
            d[0x02] = 0x03
            d[0x03] = 0x03
        }
        d[0x05] = calibrate ? 0x01 : 0x00
        d.setBE16(UInt16(g.dpi) | 0x8000, at: 0x08)
        d.setBE16(UInt16(g.dpi) | 0x8000, at: 0x0a)
        d.setBE32(UInt32(g.x), at: 0x0c)
        d.setBE32(UInt32(g.y), at: 0x10)
        d.setBE32(UInt32(g.rawWidth), at: 0x14)
        d.setBE32(UInt32(g.height), at: 0x18)
        d[0x1c] = g.channels == 3 ? 0x08 : 0x04
        d[0x1d] = UInt8(8 * g.channels)  // bits per pixel
        d[0x1f] = 0x01
        d[0x20] = 0xff
        d[0x21] = 0x81
        d[0x23] = 0x02
        d[0x24] = 0x01
        d[0x30] = 0x01
        try exec(.scanParam3, out: d)
    }

    private func waitUntilReady() throws {
        let deadline = Date().addingTimeInterval(120)
        while true {
            let s = try queryStatus3()
            if s[0] & 0x03 != 0 { return }
            if isCancelled { throw PixmaError.cancelled }
            if Date() > deadline { throw PixmaError.timeout("scanner did not become ready") }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// Reads one image block: a 16-byte header (status, block flags, length) followed by data.
    private func readImageBlock(small: Bool) throws -> (flags: UInt8, data: Data) {
        var cmd = Data(count: 16)
        cmd.setBE16(Cmd.readImage.rawValue, at: 0)
        cmd.setBE32(UInt32(small ? 32 + 8 : (Self.imageBlockSize / 65536) * 65536 + 8), at: 0x0c)
        try connection.write(cmd)

        var response = try connection.readChunk()
        while response.count < 8 { response += try connection.readChunk() }
        try checkStatus(response)
        while response.count < 16 { response += try connection.readChunk() }
        let flags = response[response.startIndex + 8]
        let length = Int(response.be32(at: 12))
        guard length <= 2 * Self.imageBlockSize else {
            throw PixmaError.protocolError("image block of \(length) bytes is larger than requested")
        }
        while response.count < 16 + length {
            let chunk = try connection.readChunk()
            if chunk.isEmpty { throw PixmaError.protocolError("image block truncated") }
            response += chunk
        }
        return (flags, Data(response[(response.startIndex + 16)..<(response.startIndex + 16 + length)]))
    }

    // MARK: - Scanning

    /// Scans one or more pages. `onPage` receives each finished page; returning `false`
    /// stops an ADF job after the current page.
    ///
    /// Raw device lines are `rawWidth` pixels wide, pixel-interleaved RGB or 8-bit gray;
    /// they are cropped to the requested width before being handed out.
    public func scan(_ request: ScanRequest, progress: ((_ page: Int, _ fraction: Double) -> Void)? = nil,
                     onPage: (ScannedPage) throws -> Bool) throws {
        cancelLock.lock(); cancelRequested = false; cancelLock.unlock()
        let geometry = try PageGeometry.make(request, model: model)
        PixmaLog.debug("geometry: \(geometry)")

        try connection.open()
        defer { connection.close() }

        try xmlDialog(Self.xmlStartJob)
        try xmlDialog(Self.xmlModeShift)

        var sessionOpen = false
        var finishedCleanly = false
        defer {
            if sessionOpen && !finishedCleanly { _ = try? exec(.abortSession) }
            _ = try? xmlDialog(Self.xmlEndJob)
        }

        if request.source.isADF {
            var status = try queryStatus()
            var waited = 0
            while !status.adfLoaded && waited < 3 {
                Thread.sleep(forTimeInterval: 1)
                waited += 1
                status = try queryStatus()
            }
            guard status.adfLoaded else { throw PixmaError.noPaper }
        }

        try startSession()
        sessionOpen = true
        for _ in 0..<3 { try sendGammaTable(gamma: request.gamma) }

        var pageIndex = 0
        while true {
            if pageIndex > 0 {
                Thread.sleep(forTimeInterval: 1)
                // Before each new sheet (not the back side of a duplex sheet) make sure paper remains.
                let isBackSide = request.source == .adfDuplex && pageIndex % 2 == 1
                if !isBackSide, !(try queryStatus().adfLoaded) { break }
            }
            let calibrate: Bool
            if request.source.isADF { calibrate = pageIndex == 0 } else { calibrate = lastSource != request.source }
            try sendScanParameters(geometry, source: request.source, calibrate: calibrate || request.calibrateEveryScan)
            try exec(.scanStart3)
            lastSource = request.source

            let page0 = pageIndex
            let (page, lastFlags) = try readPage(geometry) { progress?(page0, $0) }
            pageIndex += 1
            let wantMore = try onPage(page)

            // 0x38 = end of page + no more paper + no more data; flatbed always ends after one page.
            if !request.source.isADF || lastFlags == 0x38 || !wantMore { break }
        }
        _ = try? exec(.abortSession)
        finishedCleanly = true
    }

    private func readPage(_ g: PageGeometry, progress: (Double) -> Void) throws -> (ScannedPage, UInt8) {
        try waitUntilReady()
        Thread.sleep(forTimeInterval: 1)  // the Canon driver pauses here too

        var image = Data(capacity: g.bytesPerLine * g.height)
        var pending = Data()
        var lastBlock: UInt8 = 0
        var lines = 0
        let rawLine = g.rawBytesPerLine
        let cropStart = g.xShift * g.channels

        while (lastBlock & 0x28) != 0x28 {
            if isCancelled { throw PixmaError.cancelled }
            let block = try readImageBlock(small: (lastBlock & 0x20) != 0)
            lastBlock = block.flags & 0x38
            if block.data.isEmpty {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            pending += block.data
            var offset = pending.startIndex
            while pending.endIndex - offset >= rawLine {
                if lines < g.height {
                    image += pending[(offset + cropStart)..<(offset + cropStart + g.bytesPerLine)]
                    lines += 1
                }
                offset += rawLine
            }
            pending = Data(pending[offset...])
            progress(Double(lines) / Double(g.height))
        }
        PixmaLog.debug("page done: \(lines) lines, flags 0x\(String(lastBlock, radix: 16))")
        // Pad a short page so the image keeps its declared size.
        if lines < g.height {
            image += Data(repeating: 0xff, count: (g.height - lines) * g.bytesPerLine)
        }
        return (ScannedPage(geometry: g, pixels: image), lastBlock)
    }
}

/// One scanned page of 8-bit pixels (RGB interleaved or gray), top-down.
public struct ScannedPage: Sendable {
    public let geometry: PageGeometry
    public let pixels: Data
    public var width: Int { geometry.width }
    public var height: Int { geometry.height }
    public var channels: Int { geometry.channels }
    public var dpi: Int { geometry.dpi }

    public init(geometry: PageGeometry, pixels: Data) {
        self.geometry = geometry
        self.pixels = pixels
    }
}
