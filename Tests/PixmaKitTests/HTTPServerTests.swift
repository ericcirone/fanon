import XCTest
import Darwin
@testable import ESCLKit

/// The eSCL server faces the local network, so it must not buffer whatever a client sends.
final class HTTPServerTests: XCTestCase {
    private var server: HTTPServer?
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        port = UInt16.random(in: 20000...40000)
        let server = try HTTPServer(port: port, service: nil)
        server.handler = { _, reply in reply(.text("ok", status: 200)) }
        let ready = expectation(description: "listening")
        server.onStateChange = { if case .ready = $0 { ready.fulfill() } }
        server.start()
        wait(for: [ready], timeout: 5)
        self.server = server
    }

    override func tearDown() {
        server?.stop()
    }

    /// Sends `request` and returns what came back, and whether the server closed the connection.
    private func exchange(_ request: Data) -> (reply: String, closed: Bool) {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(rc, 0)
        request.withUnsafeBytes { raw in
            var offset = 0
            while offset < request.count {
                let n = send(fd, raw.baseAddress! + offset, min(65536, request.count - offset), 0)
                if n <= 0 { break }  // the server hung up on us
                offset += n
            }
        }
        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 { reply += buf[0..<n]; continue }
            let closed = n == 0 || errno == ECONNRESET
            return (String(decoding: reply, as: UTF8.self), closed)
        }
    }

    func testAnswersNormalRequest() {
        let result = exchange(Data("GET /eSCL/ScannerStatus HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8))
        XCTAssertTrue(result.reply.hasPrefix("HTTP/1.1 200"), result.reply)
    }

    func testDropsEndlessHeaders() {
        let request = "GET / HTTP/1.1\r\nX-Junk: " + String(repeating: "a", count: 100_000)
        let result = exchange(Data(request.utf8))
        XCTAssertTrue(result.closed)
        XCTAssertEqual(result.reply, "")
    }

    func testDropsOversizedChunkedBody() {
        var request = Data("POST /eSCL/ScanJobs HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let chunk = Data(repeating: 0x41, count: 256 << 10)
        for _ in 0..<6 {
            request += Data("40000\r\n".utf8) + chunk + Data("\r\n".utf8)
        }
        let result = exchange(request)
        XCTAssertTrue(result.closed)
        XCTAssertEqual(result.reply, "")
    }
}
