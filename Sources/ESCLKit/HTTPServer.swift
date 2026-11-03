import Foundation
import Network

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let query: String?
    /// Header names are lower-cased.
    public let headers: [String: String]
    public let body: Data
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func xml(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/xml; charset=utf-8")], body: Data(text.utf8))
    }

    public static func text(_ text: String, status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(text.utf8))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// A small HTTP/1.1 server on Network.framework, sufficient for eSCL clients
/// (keep-alive, Content-Length and chunked request bodies).
public final class HTTPServer {
    public typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fanon.http")
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    public var handler: Handler = { _, reply in reply(.text("not found", status: 404)) }
    public var onStateChange: (NWListener.State) -> Void = { _ in }

    /// eSCL clients open a handful of connections; more than this is someone misbehaving on the network.
    private static let maxConnections = 32

    public init(port: UInt16, service: NWListener.Service?) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = service
    }

    public var port: UInt16? { listener.port?.rawValue }

    public func start() {
        listener.stateUpdateHandler = { [weak self] state in self?.onStateChange(state) }
        listener.newConnectionHandler = { [weak self] nw in
            guard let self else { return }
            guard connections.count < Self.maxConnections else { return nw.cancel() }
            let conn = HTTPConnection(nw, queue: queue, handler: { [weak self] req, reply in
                self?.handler(req, reply)
            })
            let id = ObjectIdentifier(conn)
            connections[id] = conn
            conn.onClose = { [weak self] in self?.connections[id] = nil }
            conn.start()
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
        queue.async { [self] in
            connections.values.forEach { $0.close() }
            connections.removeAll()
        }
    }
}

final class HTTPConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private var buffer = Data()
    private var busy = false
    private var idleTimer: DispatchWorkItem?
    var onClose: () -> Void = {}

    private static let maxHeader = 64 << 10
    private static let maxBody = 1 << 20
    /// Connections waiting for a request are closed after this long, so idle sockets can't pile up.
    private static let idleTimeout: TimeInterval = 60

    init(_ connection: NWConnection, queue: DispatchQueue, handler: @escaping HTTPServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        resetIdleTimer()
        receive()
    }

    func close() { connection.cancel() }

    private func finish() {
        idleTimer?.cancel()
        let cb = onClose
        onClose = {}
        cb()
    }

    private func resetIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !busy else { return }
            connection.cancel()
        }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: timer)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                buffer += data
                resetIdleTimer()
            }
            // Never buffer more than one maximum-size request.
            guard buffer.count <= Self.maxHeader + Self.maxBody else { return connection.cancel() }
            processBuffer()
            if isComplete || error != nil {
                if !busy { connection.cancel() }
                return
            }
            receive()
        }
    }

    private func processBuffer() {
        guard !busy, let request = parseRequest() else { return }
        busy = true
        let keepAlive = request.headers["connection"]?.lowercased() != "close"
        handler(request) { [weak self] response in
            self?.queue.async { self?.send(response, keepAlive: keepAlive) }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reason(response.status))\r\n"
        var headers = response.headers
        headers.append(("Content-Length", String(response.body.count)))
        headers.append(("Connection", keepAlive ? "keep-alive" : "close"))
        headers.append(("Server", "Fanon"))
        headers.append(("Cache-Control", "no-cache"))
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            busy = false
            resetIdleTimer()
            if keepAlive { processBuffer() } else { connection.cancel() }
        })
    }

    /// Parses one complete request from the buffer, or returns nil if more data is needed.
    private func parseRequest() -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeader { connection.cancel() }
            return nil
        }
        guard headerEnd.lowerBound - buffer.startIndex <= Self.maxHeader else { connection.cancel(); return nil }
        let headText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { connection.cancel(); return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var body = Data()
        var consumed = headerEnd.upperBound
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let (decoded, end) = Self.decodeChunked(buffer, from: headerEnd.upperBound) else { return nil }
            body = decoded
            consumed = end
        } else if let len = Int(headers["content-length"] ?? "0"), len > 0 {
            guard len <= Self.maxBody else { connection.cancel(); return nil }
            guard buffer.endIndex - headerEnd.upperBound >= len else { return nil }
            body = buffer[headerEnd.upperBound..<(headerEnd.upperBound + len)]
            consumed = headerEnd.upperBound + len
        }
        buffer = Data(buffer[consumed...])

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        var path = parts[0]
        // Absolute-form targets (http://host/path) are allowed by HTTP/1.1.
        if path.hasPrefix("http://"), let url = URL(string: path) { path = url.path }
        return HTTPRequest(method: String(requestLine[0]).uppercased(), path: path,
                           query: parts.count > 1 ? parts[1] : nil, headers: headers, body: Data(body))
    }

    private static func decodeChunked(_ data: Data, from start: Data.Index) -> (Data, Data.Index)? {
        var body = Data()
        var pos = start
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: pos..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[pos..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0, size <= maxBody - body.count else { return nil }
            pos = lineEnd.upperBound
            if size == 0 {
                // Skip optional trailers up to the final blank line.
                guard let end = data.range(of: crlf, in: pos..<data.endIndex) else { return nil }
                return (body, end.upperBound)
            }
            guard data.endIndex - pos >= size + 2 else { return nil }
            body += data[pos..<(pos + size)]
            pos += size + 2
        }
    }
}
