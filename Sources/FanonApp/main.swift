import SwiftUI

struct FanonApp: App {
    @StateObject private var controller = ScanController()

    var body: some Scene {
        WindowGroup("Fanon") {
            ContentView()
                .environmentObject(controller)
                #if DEBUG
                .onAppear { if DebugSnapshot.isActive { DebugSnapshot.run(controller) } }
                #endif
        }
        .defaultSize(width: 1000, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scanner") {
                Button("Preview") { controller.preview() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(controller.isBusy || controller.scannerInfo == nil)
                Button("Scan") { controller.scan() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(controller.isBusy || controller.scannerInfo == nil)
                Divider()
                Button("Find Scanner Again") { controller.findScanner() }
            }
        }
    }
}

#if DEBUG
/// Developer aid for checking the UI without driving it by hand:
/// `FANON_SNAPSHOT=out.png [FANON_PREVIEW=glass75.png] [FANON_PRESET=book] [FANON_TRAY=3] FanonApp`
/// loads a 75 dpi image of the glass as the preview, writes the window to a PNG and quits.
/// Settings go to a separate key so the real ones are untouched.
@MainActor
enum DebugSnapshot {
    static let environment = ProcessInfo.processInfo.environment
    static var isActive: Bool { environment["FANON_SNAPSHOT"] != nil }

    static func run(_ controller: ScanController) {
        if let name = environment["FANON_PRESET"], let preset = ScanPreset(rawValue: name) { controller.apply(preset) }
        if let path = environment["FANON_PREVIEW"] { controller.loadPreview(from: URL(fileURLWithPath: path)) }
        if let n = Int(environment["FANON_TRAY"] ?? "") { controller.fillTrayFromPreview(count: n) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(environment["FANON_SNAPSHOT_DELAY"] ?? "") ?? 15)) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: environment["FANON_SNAPSHOT"]!))
            exit(0)
        }
    }
}
#endif

// SwiftPM executables use main.swift rather than @main.
FanonApp.main()
