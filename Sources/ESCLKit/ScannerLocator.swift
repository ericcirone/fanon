import Foundation
import Network
import PixmaKit

/// Identity of the scanner the bridge talks to.
public struct ScannerInfo: Equatable, Sendable {
    public var host: String
    public var mac: String
    public var model: String
}

/// Finds the MX920 on the network: an explicit host if configured, otherwise Bonjour
/// (`_canon-bjnp1._tcp`, which the printer always advertises), falling back to a BJNP broadcast.
/// Every candidate is confirmed with a BJNP discover + identity query.
public enum ScannerLocator {
    public static func locate(fixedHost: String?, bonjourTimeout: TimeInterval = 4) -> ScannerInfo? {
        if let fixedHost, !fixedHost.isEmpty {
            return probe(fixedHost)
        }
        for address in bonjourAddresses(timeout: bonjourTimeout) {
            if let info = probe(address) { return info }
        }
        return BJNPDiscovery.discover().lazy.compactMap { probe($0.address) }.first
    }

    /// Confirms that `host` answers BJNP and is a supported model.
    public static func probe(_ host: String) -> ScannerInfo? {
        guard let conn = try? BJNPConnection(host: host),
              let mac = try? conn.discover() else { return nil }
        let model = (try? conn.identity()).flatMap(IEEE1284.model(from:)) ?? "Canon scanner"
        guard model.uppercased().contains("MX92") else {
            PixmaLog.info("ignoring unsupported scanner \(model) at \(host)")
            return nil
        }
        return ScannerInfo(host: conn.resolvedAddress, mac: mac, model: model)
    }

    /// Browses for Canon BJNP services and resolves each to an IPv4 address.
    static func bonjourAddresses(timeout: TimeInterval) -> [String] {
        let queue = DispatchQueue(label: "fanon.locator")
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var addresses: [String] = []
        var resolving: [NWConnection] = []

        let browser = NWBrowser(for: .bonjour(type: "_canon-bjnp1._tcp", domain: nil), using: .udp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case .service = result.endpoint else { continue }
                // A UDP "connection" resolves the service without sending anything.
                let params = NWParameters.udp
                (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
                let conn = NWConnection(to: result.endpoint, using: params)
                conn.stateUpdateHandler = { state in
                    if case .ready = state,
                       case .hostPort(let host, _)? = conn.currentPath?.remoteEndpoint {
                        var text = "\(host)"
                        if let pct = text.firstIndex(of: "%") { text = String(text[..<pct]) }
                        lock.lock()
                        if !addresses.contains(text) { addresses.append(text) }
                        lock.unlock()
                        conn.cancel()
                        done.signal()
                    }
                }
                lock.lock(); resolving.append(conn); lock.unlock()
                conn.start(queue: queue)
            }
        }
        browser.start(queue: queue)
        _ = done.wait(timeout: .now() + timeout)
        // Give any other services a moment to resolve, then stop.
        Thread.sleep(forTimeInterval: 0.3)
        browser.cancel()
        lock.lock(); resolving.forEach { $0.cancel() }; let result = addresses; lock.unlock()
        return result
    }
}
