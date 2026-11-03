import Foundation
import Network
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PixmaKit

/// Exposes the MX920 as an eSCL ("AirScan") scanner so macOS's built-in scanner support
/// (Image Capture, Preview, Printers & Scanners) can use it without any vendor driver.
public final class ScanBridge {
    public enum State: Equatable {
        case searching
        case ready(ScannerInfo)
        case scanning(ScannerInfo)
        case failed(String)
    }

    public var onLog: (String) -> Void = { _ in }
    public var onStateChange: (State) -> Void = { _ in }

    public private(set) var state: State = .searching {
        didSet { if state != oldValue { onStateChange(state) } }
    }

    private let fixedHost: String?
    private let port: UInt16
    private let model = ScannerModel.mx920
    private var server: HTTPServer?
    private var scanner: PixmaScanner?
    private var info: ScannerInfo?

    /// Job bookkeeping; all mutable state below is confined to `stateQueue`.
    private let stateQueue = DispatchQueue(label: "fanon.bridge.state")
    /// Device I/O happens one job at a time on this queue.
    private let scanQueue = DispatchQueue(label: "fanon.bridge.scan")
    private var jobs: [ScanJob] = []
    private var activeJob: ScanJob?
    private var adfState: String?
    private var locateTimer: DispatchSourceTimer?

    public init(fixedHost: String?, port: UInt16 = 8090) {
        self.fixedHost = fixedHost
        self.port = port
    }

    // MARK: - Lifecycle

    public func start() throws {
        state = .searching
        scanQueue.async { [weak self] in self?.locateAndServe() }
    }

    public func stop() {
        locateTimer?.cancel()
        locateTimer = nil
        server?.stop()
        server = nil
        scanner?.cancel()
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        onLog("\(stamp) \(message)")
    }

    private func locateAndServe() {
        log("Looking for the scanner\(fixedHost.map { " at \($0)" } ?? " on the network")…")
        guard let found = ScannerLocator.locate(fixedHost: fixedHost) else {
            state = .failed("Scanner not found")
            log("Scanner not found; retrying in 30 s")
            scanQueue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.locateAndServe() }
            return
        }
        do {
            scanner = try PixmaScanner(host: found.host, model: model)
            info = found
            log("Found \(found.model) at \(found.host)")
            if server == nil { try startServer(for: found) }
            state = .ready(found)
        } catch {
            state = .failed("\(error)")
            log("Cannot start bridge: \(error)")
        }
    }

    /// Re-resolves the scanner after a network error (e.g. its DHCP address changed).
    /// Returns the new scanner if it moved.
    private func relocate() -> PixmaScanner? {
        guard fixedHost == nil, let found = ScannerLocator.locate(fixedHost: nil), found != info,
              let s = try? PixmaScanner(host: found.host, model: model) else { return nil }
        scanner = s
        info = found
        log("Scanner moved to \(found.host)")
        state = .ready(found)
        return s
    }

    private static func isConnectivityError(_ error: Error) -> Bool {
        switch error as? PixmaError {
        case .network?, .timeout?: return true
        default: return false
        }
    }

    var uuid: String {
        let mac = (info?.mac ?? "000000000000").lowercased()
        return "6b1d7a2e-5ca9-4e0b-8a3f-\(mac.padding(toLength: 12, withPad: "0", startingAt: 0))"
    }

    var serviceName: String { "\(info?.model ?? "Canon MX920 series") (Fanon)" }

    private func startServer(for info: ScannerInfo) throws {
        let hostName = ProcessInfo.processInfo.hostName
        let base = "http://\(hostName):\(port)"
        let txt: [String: String] = [
            "txtvers": "1",
            "vers": ESCL.version,
            "rs": "eSCL",
            "ty": info.model,
            "product": "(\(info.model))",
            "note": "",
            "pdl": ESCL.documentFormats.map(\.rawValue).joined(separator: ","),
            "uuid": uuid,
            "cs": "color,grayscale",
            "is": "platen,adf",
            "duplex": "T",
            "adminurl": "\(base)/",
            "representation": "\(base)/icon.png",
        ]
        let service = NWListener.Service(name: serviceName, type: "_uscan._tcp", domain: nil,
                                         txtRecord: NWTXTRecord(txt))
        let server = try HTTPServer(port: port, service: service)
        server.handler = { [weak self] req, reply in
            guard let self else { return reply(.text("gone", status: 503)) }
            self.stateQueue.async { self.route(req, reply) }
        }
        server.onStateChange = { [weak self] st in
            switch st {
            case .ready: self?.log("AirScan service \"\(self?.serviceName ?? "")\" listening on port \(self?.port ?? 0)")
            case .failed(let e): self?.log("HTTP listener failed: \(e)"); self?.state = .failed("Listener failed: \(e)")
            default: break
            }
        }
        server.start()
        self.server = server
    }

    // MARK: - Routing (on stateQueue)

    private func route(_ req: HTTPRequest, _ reply: @escaping (HTTPResponse) -> Void) {
        let base = "http://\(req.headers["host"] ?? "localhost:\(port)")"
        let path = req.path.hasSuffix("/") && req.path.count > 1 ? String(req.path.dropLast()) : req.path
        if PixmaLog.verbose { log("\(req.method) \(req.path)") }

        switch (req.method, path) {
        case ("GET", "/eSCL/ScannerCapabilities"):
            let device = ESCL.Device(makeAndModel: info?.model ?? model.name, serial: info?.mac ?? "",
                                     uuid: uuid, baseURL: base)
            reply(.xml(ESCL.capabilities(device, model: model)))

        case ("GET", "/eSCL/ScannerStatus"):
            pruneJobs()
            reply(.xml(ESCL.status(state: activeJob == nil ? "Idle" : "Processing",
                                   adfState: adfState, jobs: jobs.map { $0.info() })))

        case ("POST", "/eSCL/ScanJobs"):
            createJob(req, base: base, reply)

        case ("GET", "/"), ("GET", "/index.html"):
            reply(HTTPResponse(status: 200, headers: [("Content-Type", "text/html; charset=utf-8")],
                               body: Data(adminPage().utf8)))

        case ("GET", "/icon.png"):
            reply(HTTPResponse(status: 200, headers: [("Content-Type", "image/png")], body: Self.icon))

        default:
            let parts = path.split(separator: "/").map(String.init)
            // /eSCL/ScanJobs/{uuid}[/NextDocument|/ScanImageInfo]
            if parts.count >= 3, parts[0] == "eSCL", parts[1] == "ScanJobs",
               let job = jobs.first(where: { $0.id == parts[2] }) {
                switch (req.method, parts.count > 3 ? parts[3] : "") {
                case ("GET", "NextDocument"): return nextDocument(job, reply)
                case ("GET", "ScanImageInfo"):
                    if let page = job.lastPage { return reply(.xml(ESCL.imageInfo(jobUUID: job.id, page: page))) }
                    return reply(.text("no image yet", status: 404))
                case ("DELETE", ""):
                    cancel(job)
                    return reply(HTTPResponse(status: 200))
                default: break
                }
            }
            reply(.text("not found", status: 404))
        }
    }

    private func pruneJobs() {
        jobs.removeAll { $0.finished && Date().timeIntervalSince($0.created) > 300 }
    }

    private func createJob(_ req: HTTPRequest, base: String, _ reply: @escaping (HTTPResponse) -> Void) {
        guard let settings = ESCL.parseSettings(req.body) else {
            return reply(.text("invalid ScanSettings", status: 400))
        }
        guard activeJob == nil, let scanner, let info else {
            return reply(.text("scanner busy", status: 503))
        }
        let request = settings.scanRequest(model: model)
        let job = ScanJob(settings: settings, request: request)
        activeJob = job
        jobs.append(job)
        log("Job \(job.id.prefix(8)): \(request.source) \(request.mode) \(request.dpi) dpi → \(settings.format.rawValue)")

        scanQueue.async { [weak self] in
            guard let self else { return }
            // For the feeder, refuse the job up front if it is empty, as eSCL scanners do.
            if request.source.isADF {
                let status = try? scanner.fetchStatus()
                let loaded = status?.adfLoaded ?? true
                self.stateQueue.async {
                    self.adfState = loaded ? "ScannerAdfLoaded" : "ScannerAdfEmpty"
                    if !loaded {
                        job.fail(PixmaError.noPaper)
                        self.activeJob = nil
                        self.jobs.removeAll { $0 === job }
                        self.log("Job \(job.id.prefix(8)): feeder is empty")
                        reply(.xml(ESCL.status(state: "Idle", adfState: "ScannerAdfEmpty", jobs: []), status: 409))
                    } else {
                        reply(HTTPResponse(status: 201, headers: [("Location", "\(base)/eSCL/ScanJobs/\(job.id)")]))
                    }
                }
                if !loaded { return }
            } else {
                self.stateQueue.async {
                    reply(HTTPResponse(status: 201, headers: [("Location", "\(base)/eSCL/ScanJobs/\(job.id)")]))
                }
            }
            self.run(job, scanner: scanner, info: info)
        }
    }

    // MARK: - Scanning (on scanQueue)

    private func run(_ job: ScanJob, scanner: PixmaScanner, info: ScannerInfo) {
        state = .scanning(info)
        let start = Date()
        var scanner = scanner
        var retried = false
        while true {
            do {
                try scanner.scan(job.request) { [weak self] page in
                    guard let self else { return false }
                    let document = try ImageEncoder.encode([page], as: job.settings.format)
                    stateQueue.sync { job.add(page: page, document: document) }
                    log("Job \(job.id.prefix(8)): page \(job.pagesScanned) \(page.width)×\(page.height) (\(document.count / 1024) KB)")
                    return !stateQueue.sync { job.cancelled }
                }
                stateQueue.sync { job.complete() }
                log(String(format: "Job \(job.id.prefix(8)) finished in %.1f s", Date().timeIntervalSince(start)))
            } catch {
                // If the printer vanished before any page was scanned, it may have a new address.
                if Self.isConnectivityError(error), !retried, stateQueue.sync(execute: { job.pagesScanned }) == 0, let moved = relocate() {
                    log("Job \(job.id.prefix(8)): retrying at \(moved.connection.host)")
                    scanner = moved
                    retried = true
                    continue
                }
                log("Job \(job.id.prefix(8)) failed: \(error)")
                stateQueue.sync { job.fail(error) }
            }
            break
        }
        stateQueue.sync { if activeJob === job { activeJob = nil } }
        state = .ready(self.info ?? info)
    }

    // MARK: - Job transfer (on stateQueue)

    private func nextDocument(_ job: ScanJob, _ reply: @escaping (HTTPResponse) -> Void) {
        job.waitForDocument { document in
            guard let document else { return reply(.text("no more documents", status: 404)) }
            reply(HTTPResponse(status: 200, headers: [("Content-Type", job.settings.format.rawValue)], body: document))
        }
    }

    private func cancel(_ job: ScanJob) {
        guard !job.finished else { return }
        job.cancelled = true
        if activeJob === job { scanner?.cancel() }
        log("Job \(job.id.prefix(8)) cancelled by client")
    }

    private func adminPage() -> String {
        let status: String
        switch state {
        case .searching: status = "Searching for scanner…"
        case .ready(let i): status = "Ready — \(ESCL.escape(i.model)) at \(ESCL.escape(i.host))"
        case .scanning(let i): status = "Scanning — \(ESCL.escape(i.model)) at \(ESCL.escape(i.host))"
        case .failed(let m): status = "Problem: \(ESCL.escape(m))"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Fanon Bridge</title>
        <style>body{font:15px -apple-system,sans-serif;margin:2em;max-width:40em}</style></head>
        <body><h1>Fanon Bridge</h1><p>\(status)</p>
        <p>This Mac shares the scanner as an AirScan device named <b>\(ESCL.escape(serviceName))</b>.
        Open Image Capture or Preview → File → Import from Scanner to use it.</p></body></html>
        """
    }

    /// A simple generated icon (flatbed scanner glyph) for clients that show one.
    static let icon: Data = {
        let size = 128
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 8, y: 28, width: 112, height: 56), cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(CGColor(red: 0.55, green: 0.78, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 18, y: 66, width: 92, height: 10))
        ctx.setFillColor(CGColor(red: 0.85, green: 0.87, blue: 0.90, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 8, y: 84, width: 112, height: 16), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }()
}

/// One eSCL job. Accessed only on the bridge's state queue.
final class ScanJob {
    let id = UUID().uuidString.lowercased()
    let settings: ESCL.ScanSettings
    let request: ScanRequest
    let created = Date()
    var cancelled = false
    private(set) var finished = false
    private(set) var error: Error?
    private(set) var pagesScanned = 0
    private(set) var pagesTransferred = 0
    private(set) var lastPage: ScannedPage?
    private var documents: [Data] = []
    private var waiters: [(Data?) -> Void] = []

    init(settings: ESCL.ScanSettings, request: ScanRequest) {
        self.settings = settings
        self.request = request
    }

    func add(page: ScannedPage, document: Data) {
        pagesScanned += 1
        lastPage = page
        documents.append(document)
        flush()
    }

    func complete() {
        finished = true
        flush()
    }

    func fail(_ error: Error) {
        self.error = error
        finished = true
        flush()
    }

    func waitForDocument(_ completion: @escaping (Data?) -> Void) {
        waiters.append(completion)
        flush()
    }

    private func flush() {
        while !waiters.isEmpty {
            if !documents.isEmpty {
                let doc = documents.removeFirst()
                pagesTransferred += 1
                waiters.removeFirst()(doc)
            } else if finished {
                waiters.removeFirst()(nil)
            } else {
                return
            }
        }
    }

    func info() -> ESCL.JobInfo {
        let state: String
        let reason: String
        if !finished {
            state = "Processing"; reason = "JobScanning"
        } else if cancelled {
            state = "Canceled"; reason = "JobCanceledByUser"
        } else if error != nil {
            state = "Aborted"; reason = "JobAborted"
        } else {
            state = "Completed"; reason = "JobCompletedSuccessfully"
        }
        return ESCL.JobInfo(uuid: id, age: Int(Date().timeIntervalSince(created)),
                            imagesCompleted: pagesScanned, imagesToTransfer: pagesScanned - pagesTransferred,
                            state: state, reason: reason)
    }
}
