import Foundation
import Darwin

/// Canon BJNP ("Bubble Jet Network Protocol") transport for the scanner service.
///
/// Every message starts with a 16-byte header:
///
///     char[4]  "BJNP"
///     u8       device type (0x02 = scanner command, 0x82 = scanner response)
///     u8       command code
///     u16be    0
///     u16be    sequence number
///     u16be    session id (assigned by the device in the job-details reply)
///     u32be    payload length
///
/// Control messages (discover, identity, job details, close) travel over UDP; the PIXMA
/// command stream is tunnelled over a TCP connection to the same port (8612), where each
/// write is acknowledged and each read must be explicitly requested.
public final class BJNPConnection {
    public static let scanPort: UInt16 = 8612
    /// Far larger than any reply the scanner sends (image blocks are at most 512 KB), so a corrupt or
    /// spoofed length can't make us allocate gigabytes.
    static let maxPayload = 16 << 20

    enum Command: UInt8 {
        case udpDiscover = 0x01
        case udpJobDetails = 0x10
        case udpClose = 0x11
        case tcpRead = 0x20
        case tcpSend = 0x21
        case udpGetID = 0x30
    }

    struct Header {
        static let size = 16
        var devType: UInt8 = 0x02
        var command: UInt8
        var sequence: UInt16
        var session: UInt16
        var payloadLength: UInt32

        func encoded() -> Data {
            var d = Data("BJNP".utf8)
            d.append(devType)
            d.append(command)
            d.append(contentsOf: [0, 0])
            d.append(contentsOf: [UInt8(sequence >> 8), UInt8(sequence & 0xff)])
            d.append(contentsOf: [UInt8(session >> 8), UInt8(session & 0xff)])
            var len = Data(count: 4)
            len.setBE32(payloadLength, at: 0)
            d.append(len)
            return d
        }

        init(command: UInt8, sequence: UInt16, session: UInt16, payloadLength: UInt32) {
            self.command = command
            self.sequence = sequence
            self.session = session
            self.payloadLength = payloadLength
        }

        init?(_ d: Data) {
            guard d.count >= Header.size, d.prefix(4) == Data("BJNP".utf8) else { return nil }
            let b = d.startIndex
            devType = d[b + 4]
            command = d[b + 5]
            sequence = d.be16(at: 8)
            session = d.be16(at: 10)
            payloadLength = d.be32(at: 12)
        }
    }

    public let host: String
    public let port: UInt16
    /// Timeout for network operations. The scanner can pause for several seconds while it
    /// calibrates or moves the carriage home, so this is generous.
    public var timeout: TimeInterval = 20

    private var address = sockaddr_storage()
    private var addressLength: socklen_t = 0
    private var tcpSocket: Int32 = -1
    private var serial: UInt16 = 0xffff  // first ++ yields 0, matching the Canon driver
    private var sessionID: UInt16 = 0
    private var lastCommand: UInt8 = 0

    public init(host: String, port: UInt16 = BJNPConnection.scanPort) throws {
        self.host = host
        self.port = port
        try resolve()
    }

    deinit {
        closeTCPSocket()
    }

    public var isOpen: Bool { tcpSocket >= 0 }

    /// The scanner's IP address as a string, after resolution.
    public var resolvedAddress: String {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var addr = address
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, addressLength, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return rc == 0 ? String(cString: buf) : host
    }

    private func resolve() throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let first = result else {
            throw PixmaError.network("cannot resolve \(host): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(result) }
        // Prefer IPv4: the scanner's IPv6 stack is link-local only and needs a scope id.
        var chosen = first
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let cur = p {
            if cur.pointee.ai_family == AF_INET { chosen = cur; break }
            p = cur.pointee.ai_next
        }
        memcpy(&address, chosen.pointee.ai_addr, Int(chosen.pointee.ai_addrlen))
        addressLength = chosen.pointee.ai_addrlen
    }

    private var family: Int32 { Int32(address.ss_family) }

    private func nextHeader(_ command: Command, payloadLength: Int) -> Header {
        serial &+= 1
        lastCommand = command.rawValue
        return Header(command: command.rawValue, sequence: serial, session: sessionID,
                      payloadLength: UInt32(payloadLength))
    }

    // MARK: - Socket helpers

    private static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func connectSocket(_ fd: Int32) -> Int32 {
        var addr = address
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addressLength) }
        }
    }

    private static func errnoString() -> String { String(cString: strerror(errno)) }

    // MARK: - UDP

    /// Sends a UDP control command and returns the device's reply (header + payload).
    private func udpCommand(_ command: Command, payload: Data = Data(), retries: Int = 3,
                            replyTimeout: TimeInterval = 3) throws -> Data {
        let header = nextHeader(command, payloadLength: payload.count)
        let packet = header.encoded() + payload

        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw PixmaError.network("udp socket: \(Self.errnoString())") }
        defer { Darwin.close(fd) }
        guard connectSocket(fd) == 0 else { throw PixmaError.network("udp connect: \(Self.errnoString())") }
        Self.setTimeout(fd, replyTimeout)

        var buf = [UInt8](repeating: 0, count: 4096)
        for attempt in 0..<retries {
            let sent = packet.withUnsafeBytes { send(fd, $0.baseAddress, packet.count, 0) }
            guard sent == packet.count else {
                PixmaLog.debug("udp send failed (attempt \(attempt)): \(Self.errnoString())")
                continue
            }
            // Skip stale replies to earlier commands (they carry another sequence number).
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n < 0 { break }  // timeout -> retry
                let reply = Data(buf[0..<n])
                guard let h = Header(reply) else { continue }
                if h.sequence == header.sequence && h.command == command.rawValue {
                    PixmaLog.debug("udp \(command) reply: \(reply.prefix(48).hexDump)")
                    return reply
                }
            }
        }
        throw PixmaError.timeout("no reply from \(host) to \(command)")
    }

    /// CMD_UDP_DISCOVER: returns the device MAC address (hex), proving the scan service is up.
    public func discover() throws -> String {
        let reply = try udpCommand(.udpDiscover)
        // header(16) + 00 01 08 00 + mac_len + addr_len + mac[6]
        guard reply.count >= 28 else { throw PixmaError.protocolError("short discover reply") }
        let mac = reply[(reply.startIndex + 22)..<(reply.startIndex + 28)]
        return mac.map { String(format: "%02X", $0) }.joined()
    }

    /// CMD_UDP_GET_ID: returns the IEEE-1284 device id string.
    public func identity() throws -> String {
        let reply = try udpCommand(.udpGetID)
        guard reply.count > Header.size + 2 else { throw PixmaError.protocolError("short identity reply") }
        let body = reply.dropFirst(Header.size + 2)
        return String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Writes an ASCII string as UTF-16BE into a fixed-size field.
    private static func utf16Field(_ s: String, size: Int) -> Data {
        var d = Data(count: size)
        for (i, c) in s.utf8.prefix(size / 2 - 1).enumerated() {
            d[2 * i + 1] = c
        }
        return d
    }

    private func sendJobDetails(title: String) throws {
        let hostname = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "mac"
        var payload = Data(count: 8)
        payload += Self.utf16Field(hostname, size: 64)
        payload += Self.utf16Field(NSUserName(), size: 64)
        payload += Self.utf16Field(title, size: 256)
        let reply = try udpCommand(.udpJobDetails, payload: payload)
        guard let h = Header(reply) else { throw PixmaError.protocolError("bad job-details reply") }
        // Bytes 6-7 carry an error code; 0x8502 means another job still owns the scanner.
        let error = reply.be16(at: 6)
        if error != 0 {
            PixmaLog.debug(String(format: "job details rejected with 0x%04x", error))
            throw PixmaError.busy
        }
        sessionID = h.session
        PixmaLog.debug("job session id = \(sessionID)")
    }

    // MARK: - TCP session

    /// Announces a scan job and opens the TCP command channel.
    public func open(jobTitle: String = "Fanon", busyTimeout: TimeInterval = 30) throws {
        if isOpen { return }
        // The device accepts one job at a time (it may still be finishing a copy or another
        // computer's scan), so wait a while for it to become free.
        let busyDeadline = Date().addingTimeInterval(busyTimeout)
        while true {
            do {
                try sendJobDetails(title: jobTitle)
                break
            } catch PixmaError.busy where Date() < busyDeadline {
                Thread.sleep(forTimeInterval: 2)
            }
        }

        let deadline = Date().addingTimeInterval(4)
        while true {
            let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { throw PixmaError.network("tcp socket: \(Self.errnoString())") }
            var one: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Self.setTimeout(fd, timeout)
            if connectSocket(fd) == 0 {
                tcpSocket = fd
                PixmaLog.debug("tcp connected to \(resolvedAddress):\(port)")
                return
            }
            let err = Self.errnoString()
            Darwin.close(fd)
            if Date() > deadline { throw PixmaError.network("cannot connect to \(host):\(port): \(err)") }
            usleep(100_000)
        }
    }

    private func closeTCPSocket() {
        if tcpSocket >= 0 {
            Darwin.close(tcpSocket)
            tcpSocket = -1
        }
    }

    /// Closes the TCP channel and tells the device the job is finished.
    public func close() {
        guard isOpen else { return }
        _ = try? udpCommand(.udpClose, retries: 1)
        closeTCPSocket()
    }

    private func sendAll(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < data.count {
                let n = send(tcpSocket, raw.baseAddress! + offset, data.count - offset, 0)
                if n <= 0 { throw PixmaError.network("tcp send: \(Self.errnoString())") }
                offset += n
            }
        }
    }

    private func receiveExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var got = 0
        try data.withUnsafeMutableBytes { raw in
            while got < count {
                let n = recv(tcpSocket, raw.baseAddress! + got, count - got, 0)
                if n == 0 { throw PixmaError.network("scanner closed the connection") }
                if n < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw PixmaError.timeout("waiting for scanner data") }
                    throw PixmaError.network("tcp recv: \(Self.errnoString())")
                }
                got += n
            }
        }
        return data
    }

    private func receiveHeader() throws -> Header {
        let raw = try receiveExactly(Header.size)
        guard let h = Header(raw) else { throw PixmaError.protocolError("bad BJNP header: \(raw.hexDump)") }
        guard h.command == lastCommand, h.sequence == serial else {
            throw PixmaError.protocolError("unexpected BJNP reply cmd=\(h.command) seq=\(h.sequence), expected cmd=\(lastCommand) seq=\(serial)")
        }
        return h
    }

    /// Sends a block of PIXMA command bytes; the device acknowledges with the byte count.
    public func write(_ data: Data) throws {
        guard isOpen else { throw PixmaError.network("connection not open") }
        let header = nextHeader(.tcpSend, payloadLength: data.count)
        try sendAll(header.encoded() + data)
        let reply = try receiveHeader()
        guard reply.payloadLength == 4 else {
            throw PixmaError.protocolError("write ack has \(reply.payloadLength) bytes, expected 4")
        }
        let ack = try receiveExactly(4).be32(at: 0)
        guard ack == data.count else {
            throw PixmaError.protocolError("scanner acknowledged \(ack) of \(data.count) bytes")
        }
    }

    /// Requests the next block of response data from the device.
    public func readChunk() throws -> Data {
        guard isOpen else { throw PixmaError.network("connection not open") }
        let header = nextHeader(.tcpRead, payloadLength: 0)
        try sendAll(header.encoded())
        let reply = try receiveHeader()
        guard reply.payloadLength <= Self.maxPayload else {
            throw PixmaError.protocolError("reply of \(reply.payloadLength) bytes is too large")
        }
        return reply.payloadLength == 0 ? Data() : try receiveExactly(Int(reply.payloadLength))
    }
}

// MARK: - Discovery

public struct DiscoveredScanner: Hashable, CustomStringConvertible {
    public let address: String
    public let mac: String
    public var model: String

    public var description: String { "\(model) at \(address) (MAC \(mac))" }
}

public enum BJNPDiscovery {
    /// Broadcasts a BJNP discover packet on every IPv4 interface and collects the replies.
    public static func discover(timeout: TimeInterval = 2) -> [DiscoveredScanner] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))

        let packet = BJNPConnection.Header(command: BJNPConnection.Command.udpDiscover.rawValue,
                                           sequence: 0, session: 0, payloadLength: 0).encoded()
        for target in broadcastAddresses() {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = BJNPConnection.scanPort.bigEndian
            sin.sin_addr = target
            _ = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &sin) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var found: [String: DiscoveredScanner] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            let remaining = max(0.05, deadline.timeIntervalSinceNow)
            var tv = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            if n < 0 { break }
            let reply = Data(buf[0..<n])
            guard n >= 28, let h = BJNPConnection.Header(reply), h.devType == 0x82, h.command == 0x01 else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            let mac = reply[22..<28].map { String(format: "%02X", $0) }.joined()
            found[ip] = DiscoveredScanner(address: ip, mac: mac, model: "Canon scanner")
        }

        // Fill in the model name from the IEEE-1284 identity.
        return found.values.map { s in
            var s = s
            if let conn = try? BJNPConnection(host: s.address), let id = try? conn.identity(),
               let model = IEEE1284.model(from: id) {
                s.model = model
            }
            return s
        }.sorted { $0.address < $1.address }
    }

    private static func broadcastAddresses() -> [in_addr] {
        var result: [in_addr] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [in_addr(s_addr: INADDR_BROADCAST)] }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
               let bcast = cur.pointee.ifa_dstaddr {
                bcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { result.append($0.pointee.sin_addr) }
            }
            p = cur.pointee.ifa_next
        }
        return result.isEmpty ? [in_addr(s_addr: INADDR_BROADCAST)] : result
    }
}

public enum IEEE1284 {
    /// Parses "MFG:Canon;MDL:MX920 series;..." into "Canon MX920 series".
    public static func model(from id: String) -> String? {
        var fields: [String: String] = [:]
        for part in id.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { fields[kv[0].uppercased()] = kv[1] }
        }
        let model = fields["MDL"] ?? fields["MODEL"]
        let make = fields["MFG"] ?? fields["MANUFACTURER"] ?? "Canon"
        guard let model else { return nil }
        return model.hasPrefix(make) ? model : "\(make) \(model)"
    }
}
