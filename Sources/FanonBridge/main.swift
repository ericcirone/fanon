import AppKit
import ServiceManagement
import PixmaKit
import ESCLKit

/// Menu-bar agent that runs the AirScan bridge for the Canon MX920 series.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var bridge: ScanBridge?
    private var bridgeState: ScanBridge.State = .searching
    private var logLines: [String] = []
    private let defaults = UserDefaults.standard

    private var fixedHost: String? {
        get { defaults.string(forKey: "ScannerHost").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: "ScannerHost") }
    }

    private var port: UInt16 {
        let p = defaults.integer(forKey: "Port")
        return p > 0 && p < 65536 ? UInt16(p) : 8090
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "scanner", accessibilityDescription: "Fanon Bridge")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        PixmaLog.sink = { [weak self] line in DispatchQueue.main.async { self?.appendLog(line) } }
        migrateSettings()
        startBridge()
    }

    /// Carries over the scanner address and port saved before the bridge was renamed from IJScanBridge.
    private func migrateSettings() {
        guard let old = UserDefaults(suiteName: "io.github.ijscanbridge") else { return }
        for key in ["ScannerHost", "Port"] where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.stop()
    }

    private func startBridge() {
        bridge?.stop()
        let bridge = ScanBridge(fixedHost: fixedHost, port: port)
        bridge.onLog = { [weak self] line in DispatchQueue.main.async { self?.appendLog(line) } }
        bridge.onStateChange = { [weak self] state in DispatchQueue.main.async { self?.update(state) } }
        self.bridge = bridge
        do {
            try bridge.start()
        } catch {
            update(.failed("\(error)"))
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    private func update(_ state: ScanBridge.State) {
        bridgeState = state
        let symbol: String
        switch state {
        case .searching: symbol = "scanner"
        case .ready: symbol = "scanner.fill"
        case .scanning: symbol = "arrow.down.doc.fill"
        case .failed: symbol = "exclamationmark.triangle"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Fanon Bridge")
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        switch bridgeState {
        case .searching: status = "Searching for scanner…"
        case .ready(let i): status = "Ready: \(i.model)"
        case .scanning(let i): status = "Scanning on \(i.model)…"
        case .failed(let m): status = m
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        if case .ready(let i) = bridgeState { menu.addItem(withTitle: "Address: \(i.host)", action: nil, keyEquivalent: "") }
        if case .scanning(let i) = bridgeState { menu.addItem(withTitle: "Address: \(i.host)", action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(item("Open Image Capture", #selector(openImageCapture)))
        menu.addItem(item("Scanner Address…", #selector(setAddress)))
        menu.addItem(item("Reconnect", #selector(reconnect)))
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Show Log", #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Fanon Bridge", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openImageCapture() {
        let url = URL(fileURLWithPath: "/System/Applications/Image Capture.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    @objc private func setAddress() {
        let alert = NSAlert()
        alert.messageText = "Scanner Address"
        alert.informativeText = "Leave empty to find the MX920 automatically with Bonjour. Enter an IP address or host name if automatic discovery doesn't work on your network."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = fixedHost ?? ""
        field.placeholderString = "Automatic"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        fixedHost = field.stringValue.trimmingCharacters(in: .whitespaces)
        startBridge()
    }

    @objc private func reconnect() { startBridge() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func showLog() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FanonBridge.log")
        try? logLines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
