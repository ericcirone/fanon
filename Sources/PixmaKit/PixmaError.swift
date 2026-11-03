import Foundation

public enum PixmaError: Error, CustomStringConvertible, Equatable {
    case network(String)
    case timeout(String)
    case protocolError(String)
    case busy
    case cancelled
    case noPaper
    case deviceFailed(String)
    case invalidParameter(String)

    public var description: String {
        switch self {
        case .network(let m): return "Network error: \(m)"
        case .timeout(let m): return "Timed out: \(m)"
        case .protocolError(let m): return "Protocol error: \(m)"
        case .busy: return "Scanner is busy"
        case .cancelled: return "Scan cancelled"
        case .noPaper: return "No paper in the document feeder"
        case .deviceFailed(let m): return "Scanner reported an error: \(m)"
        case .invalidParameter(let m): return "Invalid parameter: \(m)"
        }
    }
}

/// Minimal logger; the CLI and app both route through this so `--verbose` works everywhere.
public enum PixmaLog {
    public nonisolated(unsafe) static var verbose = false
    public nonisolated(unsafe) static var sink: (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    public static func debug(_ message: @autoclosure () -> String) {
        if verbose { sink("[pixma] " + message()) }
    }

    public static func info(_ message: @autoclosure () -> String) {
        sink("[pixma] " + message())
    }
}

extension Data {
    func be16(at i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) << 8 | UInt16(self[b + 1])
    }

    func be32(at i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) << 24 | UInt32(self[b + 1]) << 16 | UInt32(self[b + 2]) << 8 | UInt32(self[b + 3])
    }

    mutating func setBE16(_ v: UInt16, at i: Int) {
        let b = startIndex + i
        self[b] = UInt8(v >> 8)
        self[b + 1] = UInt8(v & 0xff)
    }

    mutating func setBE32(_ v: UInt32, at i: Int) {
        let b = startIndex + i
        self[b] = UInt8(v >> 24)
        self[b + 1] = UInt8((v >> 16) & 0xff)
        self[b + 2] = UInt8((v >> 8) & 0xff)
        self[b + 3] = UInt8(v & 0xff)
    }

    var hexDump: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
