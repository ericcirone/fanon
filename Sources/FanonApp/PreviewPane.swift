import SwiftUI
import PixmaKit
import ScanProcessing

/// Shows the preview scan of the glass and lets the user drag out a scan area, or detect the page and fine-tune
/// its corners.
struct PreviewPane: View {
    @EnvironmentObject var controller: ScanController
    @State private var dragStart: CGPoint?
    @State private var dragOrigin: (rect: CGRect, quad: Quad?)?

    /// The glass in 1/300 inch.
    private let glass = ScanController.glass

    var body: some View {
        VStack(spacing: 0) {
            if controller.settings.source == .flatbed {
                PreviewToolbar()
                Divider()
            }
            GeometryReader { geo in
                let frame = fittedRect(in: geo.size)
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .underPageBackgroundColor)

                    Group {
                        if let image = controller.previewImage {
                            Image(nsImage: image).resizable().interpolation(.high)
                        } else {
                            ZStack {
                                Rectangle().fill(Color(nsColor: .textBackgroundColor))
                                VStack(spacing: 8) {
                                    Image(systemName: "doc.viewfinder").font(.system(size: 40)).foregroundStyle(.tertiary)
                                    Text(controller.settings.source == .flatbed
                                         ? "Click Preview to see what's on the glass."
                                         : "Load pages face up in the document feeder, then click Scan.")
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .padding()
                            }
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .shadow(radius: 2)
                    .offset(x: frame.minX, y: frame.minY)

                    if controller.settings.source == .flatbed {
                        selectionOverlay(frame)
                        itemsOverlay(frame)
                        if let quad = controller.settings.activeQuad {
                            quadOverlay(quad, frame)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(controller.settings.source == .flatbed ? dragGesture(frame) : nil)
            }
            .padding(16)

            if !controller.tray.isEmpty {
                Divider()
                PageTray()
            }
        }
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let scale = min(size.width / glass.width, size.height / glass.height)
        let w = glass.width * scale, h = glass.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func toView(_ p: CGPoint, _ frame: CGRect) -> CGPoint {
        let s = frame.width / glass.width
        return CGPoint(x: frame.minX + p.x * s, y: frame.minY + p.y * s)
    }

    private func toGlass(_ p: CGPoint, _ frame: CGRect) -> CGPoint {
        let s = glass.width / frame.width
        return CGPoint(x: min(max(0, (p.x - frame.minX) * s), glass.width),
                       y: min(max(0, (p.y - frame.minY) * s), glass.height))
    }

    /// The area that will be scanned, in view coordinates.
    private func scanArea(_ frame: CGRect) -> CGRect {
        let r = controller.settings.region
        let s = frame.width / glass.width
        return CGRect(x: frame.minX + r.minX * s, y: frame.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }

    @ViewBuilder
    private func selectionOverlay(_ frame: CGRect) -> some View {
        let area = scanArea(frame).intersection(frame)
        let hasQuad = controller.settings.activeQuad != nil
        if area.width > 0, area.size != frame.size {
            if !hasQuad {
                Path { p in
                    p.addRect(frame)
                    p.addRect(area)
                }
                .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            }
            Rectangle()
                .strokeBorder(Color.accentColor.opacity(hasQuad ? 0.5 : 1), style: StrokeStyle(lineWidth: hasQuad ? 1 : 2, dash: [6, 3]))
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
                .allowsHitTesting(false)
            if !hasQuad {
                let r = controller.settings.region
                sizeLabel(String(format: "%.2f × %.2f in", r.width / 300, r.height / 300))
                    .offset(x: area.minX + 4, y: area.minY + 4)
            }
        }
    }

    private func sizeLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
            .allowsHitTesting(false)
    }

    /// The detected page: shaded outside, outlined, with a handle on each corner.
    @ViewBuilder
    private func quadOverlay(_ quad: Quad, _ frame: CGRect) -> some View {
        let points = quad.points.map { toView($0, frame) }
        Path { p in
            p.addRect(frame)
            p.addLines(points)
            p.closeSubpath()
        }
        .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
        Path { p in
            p.addLines(points)
            p.closeSubpath()
        }
        .stroke(Color.accentColor, lineWidth: 2)
        .allowsHitTesting(false)
        let width = hypot(quad.topRight.x - quad.topLeft.x, quad.topRight.y - quad.topLeft.y) / 300
        let height = hypot(quad.bottomLeft.x - quad.topLeft.x, quad.bottomLeft.y - quad.topLeft.y) / 300
        let tilt = abs(quad.angle)
        sizeLabel(String(format: "%.2f × %.2f in", width, height) + (tilt >= 0.1 ? String(format: " · straightened %.1f°", tilt) : ""))
            .offset(x: min(points.map(\.x).min()! + 8, frame.maxX - 220), y: points.map(\.y).min()! + 8)
        ForEach(0..<4, id: \.self) { corner in
            CornerHandle()
                .position(points[corner])
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            var q = quad
                            var pts = q.points
                            pts[corner] = toGlass(value.location, frame)
                            q.points = pts
                            controller.setDocumentQuad(q)
                        }
                )
                .help("Drag to adjust this corner")
        }
    }

    /// Outlines of the photos that "Detect Separate Items" will save.
    @ViewBuilder
    private func itemsOverlay(_ frame: CGRect) -> some View {
        if controller.settings.processing.autoCrop == .separateItems {
            ForEach(Array(controller.detectedItems.enumerated()), id: \.offset) { n, item in
                let points = item.points.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
                Path { p in
                    p.addLines(points)
                    p.closeSubpath()
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                .allowsHitTesting(false)
                Text("\(n + 1)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.accentColor, in: Circle())
                    .position(x: points[0].x + 14, y: points[0].y + 14)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Drag inside the selection to move it; drag elsewhere to draw a new one; a click clears it.
    private func dragGesture(_ frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let s = glass.width / frame.width
                if dragStart == nil {
                    dragStart = value.startLocation
                    let current = scanArea(frame)
                    dragOrigin = controller.settings.paper == .selection && current.contains(value.startLocation)
                        ? (controller.settings.region, controller.settings.activeQuad) : nil
                }
                if let origin = dragOrigin {
                    var dx = value.translation.width * s, dy = value.translation.height * s
                    dx = min(max(dx, -origin.rect.minX), glass.width - origin.rect.maxX)
                    dy = min(max(dy, -origin.rect.minY), glass.height - origin.rect.maxY)
                    if let quad = origin.quad {
                        controller.setDocumentQuad(quad.mapped { CGPoint(x: $0.x + dx, y: $0.y + dy) })
                    } else {
                        controller.settings.selection = origin.rect.offsetBy(dx: dx, dy: dy).integral
                    }
                } else if hypot(value.translation.width, value.translation.height) > 4 {
                    let a = toGlass(value.startLocation, frame), b = toGlass(value.location, frame)
                    var settings = controller.settings
                    settings.documentQuad = nil
                    settings.selection = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                                width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
                    settings.paper = .selection
                    controller.settings = settings
                }
            }
            .onEnded { value in
                if hypot(value.translation.width, value.translation.height) <= 4, dragOrigin == nil {
                    // A plain click outside the selection scans the whole glass again.
                    if controller.settings.paper == .selection { controller.settings.paper = .fullGlass }
                    controller.clearDocumentQuad()
                } else if let sel = controller.settings.selection, sel.width < 30 || sel.height < 30 {
                    controller.settings.paper = .fullGlass
                }
                dragStart = nil
                dragOrigin = nil
            }
    }
}

private struct CornerHandle: View {
    @State private var hovering = false

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2.5))
            .frame(width: hovering ? 18 : 14, height: hovering ? 18 : 14)
            .shadow(radius: 1.5)
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

/// Above the preview: "Detect Document" (find the page and select its corners) and a hint.
private struct PreviewToolbar: View {
    @EnvironmentObject var controller: ScanController

    var body: some View {
        HStack(spacing: 8) {
            Button {
                controller.detectDocument()
            } label: {
                Label("Detect Document", systemImage: "viewfinder")
            }
            .keyboardShortcut("d", modifiers: .command)
            .help("Find the page on the glass and select its corners, so the scan is cropped and straightened to it (⌘D)")
            if controller.settings.paper == .selection {
                Button {
                    controller.clearDocumentQuad()
                    controller.settings.paper = .fullGlass
                } label: {
                    Label("Clear Selection", systemImage: "xmark")
                }
                .help("Scan the whole glass again")
            }
            Spacer()
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .controlSize(.small)
        .disabled(!controller.hasPreview || controller.isBusy)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var hint: String {
        if !controller.hasPreview { return "" }
        if controller.settings.activeQuad != nil { return "Drag a corner to adjust, or drag inside to move." }
        return "Drag on the preview to choose an area."
    }
}

/// Pages scanned with "Collect pages" on, waiting to be saved as one document.
private struct PageTray: View {
    @EnvironmentObject var controller: ScanController

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(controller.tray.enumerated()), id: \.element.id) { n, page in
                        VStack(spacing: 4) {
                            Image(nsImage: page.thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 96)
                                .background(Color.white)
                                .shadow(radius: 1)
                            Text("\(n + 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Rotate Left") { controller.rotateTrayPage(page.id, degrees: 270) }
                            Button("Rotate Right") { controller.rotateTrayPage(page.id, degrees: 90) }
                            Button("Rotate 180°") { controller.rotateTrayPage(page.id, degrees: 180) }
                            Divider()
                            Button("Move Earlier") { controller.moveTrayPage(page.id, by: -1) }
                                .disabled(n == 0)
                            Button("Move Later") { controller.moveTrayPage(page.id, by: 1) }
                                .disabled(n == controller.tray.count - 1)
                            Divider()
                            Button("Delete Page", role: .destructive) { controller.removeTrayPage(page.id) }
                        }
                        .help("Right-click to rotate, move or delete")
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
            VStack(alignment: .trailing, spacing: 6) {
                Button("Save \(controller.tray.count) Page\(controller.tray.count == 1 ? "" : "s")") { controller.saveTray() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                Button("Discard", role: .destructive) { controller.tray = [] }
            }
            .disabled(controller.isBusy)
        }
        .padding(.horizontal, 16)
        .frame(height: 130)
    }
}
