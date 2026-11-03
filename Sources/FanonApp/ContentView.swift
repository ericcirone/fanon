import SwiftUI
import ScanProcessing

struct ContentView: View {
    @EnvironmentObject var controller: ScanController

    var body: some View {
        HSplitView {
            SettingsSidebar()
                .frame(minWidth: 320, idealWidth: 340, maxWidth: 420)
            VStack(spacing: 0) {
                PreviewPane()
                Divider()
                ActionBar()
            }
            .frame(minWidth: 420)
        }
        .frame(minHeight: 640)
        .alert("Scan Failed", isPresented: Binding(get: { controller.errorMessage != nil },
                                                   set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @EnvironmentObject var controller: ScanController

    /// Rotation, with -1 meaning "Automatic".
    private var rotation: Binding<Int> {
        Binding(get: { controller.settings.processing.autoRotate ? -1 : controller.settings.processing.rotation },
                set: { value in
                    controller.settings.processing.autoRotate = value == -1
                    controller.settings.processing.rotation = max(0, value)
                })
    }

    var body: some View {
        let s = $controller.settings
        Form {
            Section("Scanner") {
                ScannerStatusRow()
                TextField("Address", text: s.scannerAddress, prompt: Text("Automatic"))
                    .help("Leave empty to find the MX920 with Bonjour, or enter its IP address.")
            }

            Section("Scan") {
                PresetRow()
                Picker("Source", selection: s.source) {
                    ForEach(SourceChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("Kind", selection: s.color) {
                    ForEach(ProcessingOptions.OutputColor.allCases) { Text($0.title).tag($0) }
                }
                .help("Automatic saves pages with only black or grey print in grayscale, for smaller files.")
                Picker("Resolution", selection: s.dpi) {
                    ForEach(controller.settings.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
                }
                Picker("Size", selection: s.paper) {
                    ForEach(PaperSize.available(for: controller.settings.source)) { Text($0.title).tag($0) }
                }
                Picker("Auto Selection", selection: s.processing.autoCrop) {
                    ForEach(ProcessingOptions.AutoCrop.allCases) { Text($0.title).tag($0) }
                }
                .help("Straighten levels tilted text. Crop Document finds the page on the glass, even one that runs off the edge, and straightens it.")
                Picker("Rotation", selection: rotation) {
                    Text("Automatic (by text)").tag(-1)
                    Text("None").tag(0)
                    Text("90° Clockwise").tag(90)
                    Text("180°").tag(180)
                    Text("90° Counterclockwise").tag(270)
                }
                if controller.settings.source == .duplex {
                    Toggle("Rotate back sides 180°", isOn: s.processing.rotateBackSides)
                }
                Toggle("Calibrate before each scan", isOn: s.calibrateEveryScan)
            }

            Section("Pages") {
                Toggle("Skip blank pages", isOn: s.processing.skipBlankPages)
                    .help("Leaves out pages with nothing on them, such as the empty backs of two-sided feeder scans.")
                Toggle("Flatten curved pages", isOn: s.processing.flattenCurvedPages)
                    .help("Straightens lines of text that bend toward a book's spine.")
                Toggle("Split facing pages", isOn: s.processing.splitFacingPages)
                    .help("Saves a two-page book spread as two separate pages.")
            }

            Section("Image Corrections") {
                Picker("Image Adjustment", selection: s.processing.autoAdjust) {
                    Text("None").tag(false)
                    Text("Auto").tag(true)
                }
                LevelPicker(title: "Reduce Dust & Scratches", level: s.processing.reduceDust)
                LevelPicker(title: "Fading Correction", level: s.processing.fadingCorrection)
                LevelPicker(title: "Grain Correction", level: s.processing.grainCorrection)
                Toggle("Gutter Correction", isOn: s.processing.gutterCorrection)
                    .help("Brightens the shadow along a book's spine.")
                Toggle("Unsharp Mask", isOn: s.processing.unsharpMask)
                Toggle("Descreen", isOn: s.processing.descreen)
                    .help("Removes the dot pattern from magazines and other printed material.")
                Toggle("Reduce Show-through", isOn: s.processing.reduceShowThrough)
                    .help("Whitens the paper so the reverse side doesn't show through.")
                Toggle("Show corrections in preview", isOn: s.previewCorrections)
            }

            Section("Save") {
                OutputFolderRow()
                TextField("Name", text: s.baseName)
                    .help("{date} and {time} are replaced with the date and time of the scan.")
                Picker("Format", selection: s.format) {
                    ForEach(OutputFormat.allCases) { Text($0.title).tag($0) }
                }
                if controller.settings.format == .pdf {
                    Toggle("Searchable text (OCR)", isOn: s.searchablePDF)
                }
                if controller.settings.format == .pdf || controller.settings.format == .jpeg {
                    Picker("Quality", selection: s.compression) {
                        ForEach(Compression.allCases) { Text($0.title).tag($0) }
                    }
                }
                Toggle("Collect pages, then save", isOn: s.collectPages)
                    .help("Scanned pages wait in a tray below the preview, where you can add more, reorder, rotate or delete them before saving them as one document.")
                Toggle("Open after scanning", isOn: s.openAfterScan)
            }
        }
        .formStyle(.grouped)
        .disabled(controller.isBusy)
        .onChange(of: controller.settings.source) { source in
            var settings = controller.settings
            if !settings.resolutions.contains(settings.dpi) { settings.dpi = settings.resolutions.last! }
            if !PaperSize.available(for: source).contains(settings.paper) {
                settings.paper = source == .flatbed ? .fullGlass : .letter
            }
            controller.settings = settings
        }
    }
}

/// Applies a preset; shows which one the current settings match.
struct PresetRow: View {
    @EnvironmentObject var controller: ScanController

    var body: some View {
        LabeledContent("Preset") {
            Menu {
                ForEach(ScanPreset.allCases) { preset in
                    Button {
                        controller.apply(preset)
                    } label: {
                        Label(preset.title, systemImage: preset.symbol)
                    }
                }
            } label: {
                Text(ScanPreset.matching(controller.settings)?.title ?? "Custom")
            }
            .fixedSize()
        }
        .help("Sets everything below for a common job. You can still change any setting afterwards.")
    }
}

struct LevelPicker: View {
    let title: String
    @Binding var level: ProcessingOptions.Level

    var body: some View {
        Picker(title, selection: $level) {
            ForEach(ProcessingOptions.Level.allCases) { Text($0.title).tag($0) }
        }
    }
}

struct ScannerStatusRow: View {
    @EnvironmentObject var controller: ScanController

    var body: some View {
        HStack {
            switch controller.scannerState {
            case .searching:
                ProgressView().controlSize(.small)
                Text("Searching…").foregroundStyle(.secondary)
            case .ready(let info):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text(info.model)
                    Text(info.host).font(.caption).foregroundStyle(.secondary)
                }
            case .notFound:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Scanner not found")
            }
            Spacer()
            Button {
                controller.findScanner()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Search again")
        }
    }
}

struct OutputFolderRow: View {
    @EnvironmentObject var controller: ScanController

    var body: some View {
        LabeledContent("Folder") {
            HStack {
                Text(URL(fileURLWithPath: controller.settings.folderPath).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") { choose() }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: controller.settings.folderPath)
        if panel.runModal() == .OK, let url = panel.url {
            controller.settings.folderPath = url.path
        }
    }
}

// MARK: - Bottom bar

struct ActionBar: View {
    @EnvironmentObject var controller: ScanController

    var body: some View {
        HStack(spacing: 12) {
            if let progress = controller.progress {
                ProgressView(value: progress).frame(width: 160)
            }
            Text(controller.status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !controller.lastSaved.isEmpty, !controller.isBusy {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(controller.lastSaved) }
                    .buttonStyle(.link)
            }
            Spacer()
            if controller.isBusy {
                Button("Cancel") { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
            Button("Preview") { controller.preview() }
                .disabled(controller.isBusy || controller.scannerInfo == nil || controller.settings.source != .flatbed)
                .help(controller.settings.source == .flatbed ? "Quick 75 dpi scan of the glass" : "Preview is only available for the flatbed")
            Button("Scan") { controller.scan() }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isBusy || controller.scannerInfo == nil)
        }
        .padding(12)
    }
}
