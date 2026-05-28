import Foundation
import PDFKit
import AppKit

// MARK: - ReportGenerator (F-014)
//
// Generates a multi-page PDF health report using PDFKit.
// Call generate(snapshot:) to get a PDFDocument, then present an NSSavePanel.
//
// Usage (call from @MainActor context):
//   let doc = await ReportGenerator.shared.generate(snapshot: snapshot)
//   ReportGenerator.presentSavePanel(document: doc)

// MARK: - Report Snapshot

/// All data needed for the report, collected on @MainActor before handing off.
struct ReportSnapshot: Sendable {
    let date: Date
    let healthScore: Int
    let cpuUsage: Double
    let ramUsedGB: Double
    let ramTotalGB: Double
    let diskFreeGB: Double
    let diskTotalGB: Double
    let batteryPercent: Int
    let batteryCycles: Int
    let batteryHealth: Double
    let junkBytes: Int64
    let threatsFound: Int
    let loginItemsCount: Int
    let lastScanDate: Date?
    let alertEntries: [AlertEntry]

    @MainActor
    static func capture(from appState: AppState) -> ReportSnapshot {
        ReportSnapshot(
            date: Date(),
            healthScore: appState.systemHealthScore,
            cpuUsage: appState.cpuUsage,
            ramUsedGB: appState.ramUsedGB,
            ramTotalGB: appState.ramTotalGB,
            diskFreeGB: appState.diskFreeGB,
            diskTotalGB: appState.diskTotalGB,
            batteryPercent: appState.batteryPercent,
            batteryCycles: appState.batteryCycles,
            batteryHealth: appState.batteryHealth,
            junkBytes: appState.totalCleanableBytes,
            threatsFound: appState.smartScanResult?.threatsFound ?? 0,
            loginItemsCount: 0,
            lastScanDate: appState.lastSmartScanDate,
            alertEntries: AlertLog.shared.entries
        )
    }
}

// MARK: - ReportGenerator

final class ReportGenerator: @unchecked Sendable {

    static let shared = ReportGenerator()
    private init() {}

    // MARK: Page geometry
    private let pageWidth:  CGFloat = 595   // A4 @ 72 dpi
    private let pageHeight: CGFloat = 842
    private let margin:     CGFloat = 50

    // MARK: - Public API

    /// Generates a PDFDocument from the given snapshot.
    func generate(snapshot: ReportSnapshot) -> PDFDocument {
        let document = PDFDocument()
        document.insert(makeCoverPage(snapshot: snapshot),    at: 0)
        document.insert(makeSystemPage(snapshot: snapshot),   at: 1)
        document.insert(makeStoragePage(snapshot: snapshot),  at: 2)
        document.insert(makeAlertsPage(snapshot: snapshot),   at: 3)
        return document
    }

    // MARK: - NSSavePanel (must be called from @MainActor)

    @MainActor
    static func presentSavePanel(document: PDFDocument) {
        let panel = NSSavePanel()
        panel.title = "Export Health Report"
        panel.allowedContentTypes = [.pdf]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "HaloHealthReport-\(formatter.string(from: Date())).pdf"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.write(to: url)
    }

    // MARK: - Pages

    private func makeCoverPage(snapshot: ReportSnapshot) -> PDFPage {
        let page = DrawablePDFPage(size: CGSize(width: pageWidth, height: pageHeight))
        page.draw { [self] ctx in
            // Dark background
            ctx.setFillColor(CGColor(red: 0.031, green: 0.047, blue: 0.078, alpha: 1)) // #080c14
            ctx.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

            let accentBlue = CGColor(red: 0.310, green: 0.486, blue: 1.0, alpha: 1)  // #4f7cff

            // Title
            drawText("Halo Health Report",
                     at: CGPoint(x: margin, y: pageHeight - 120),
                     font: .systemFont(ofSize: 32, weight: .bold),
                     color: .white, maxWidth: pageWidth - margin * 2, ctx: ctx)

            // Subtitle
            let dateStr = DateFormatter.localizedString(from: snapshot.date,
                                                        dateStyle: .long, timeStyle: .short)
            drawText("Generated \(dateStr)",
                     at: CGPoint(x: margin, y: pageHeight - 155),
                     font: .systemFont(ofSize: 13),
                     color: CGColor(gray: 0.6, alpha: 1),
                     maxWidth: pageWidth - margin * 2, ctx: ctx)

            // Health score big circle (approximate)
            let cx = pageWidth / 2
            let cy = pageHeight / 2 + 20
            let r: CGFloat = 80
            ctx.setStrokeColor(accentBlue)
            ctx.setLineWidth(8)
            ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))

            let scoreColor: CGColor = snapshot.healthScore >= 75
                ? CGColor(red: 0.133, green: 0.851, blue: 0.478, alpha: 1)   // haloGreen
                : snapshot.healthScore >= 50
                    ? CGColor(red: 0.961, green: 0.651, blue: 0.137, alpha: 1) // haloAmber
                    : CGColor(red: 1.0, green: 0.302, blue: 0.416, alpha: 1)  // haloRed

            drawText("\(snapshot.healthScore)",
                     at: CGPoint(x: cx - 28, y: cy - 22),
                     font: .systemFont(ofSize: 44, weight: .heavy),
                     color: scoreColor,
                     maxWidth: 80, ctx: ctx)

            drawText("/ 100",
                     at: CGPoint(x: cx - 16, y: cy + 22),
                     font: .systemFont(ofSize: 14),
                     color: CGColor(gray: 0.5, alpha: 1),
                     maxWidth: 60, ctx: ctx)

            drawText("System Health Score",
                     at: CGPoint(x: cx - 80, y: cy - 110),
                     font: .systemFont(ofSize: 12),
                     color: CGColor(gray: 0.6, alpha: 1),
                     maxWidth: 160, ctx: ctx)

            // Footer
            drawText("Halo — Your Mac. Elevated.  ·  com.halo.mac",
                     at: CGPoint(x: margin, y: 30),
                     font: .systemFont(ofSize: 10),
                     color: CGColor(gray: 0.4, alpha: 1),
                     maxWidth: pageWidth - margin * 2, ctx: ctx)
        }
        return page
    }

    private func makeSystemPage(snapshot: ReportSnapshot) -> PDFPage {
        let page = DrawablePDFPage(size: CGSize(width: pageWidth, height: pageHeight))
        page.draw { [self] ctx in
            drawPageBackground(ctx)
            var y = pageHeight - margin

            y = drawSectionHeader("System Overview", y: y, ctx: ctx)

            let rows: [(String, String)] = [
                ("CPU Usage",     String(format: "%.0f%%", snapshot.cpuUsage * 100)),
                ("Memory Used",   String(format: "%.1f GB / %.0f GB", snapshot.ramUsedGB, snapshot.ramTotalGB)),
                ("Disk Free",     String(format: "%.1f GB / %.0f GB", snapshot.diskFreeGB, snapshot.diskTotalGB)),
                ("Battery",       "\(snapshot.batteryPercent)% · \(snapshot.batteryCycles) cycles · \(String(format: "%.0f%%", snapshot.batteryHealth * 100)) health"),
                ("Junk Files",    ByteCountFormatter.string(fromByteCount: snapshot.junkBytes, countStyle: .file)),
                ("Threats Found", snapshot.threatsFound == 0 ? "None detected ✓" : "\(snapshot.threatsFound) threat(s)"),
            ]

            for (label, value) in rows {
                y = drawRow(label: label, value: value, y: y, ctx: ctx)
            }

            if let last = snapshot.lastScanDate {
                let rel = RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
                y = drawRow(label: "Last Smart Scan", value: rel, y: y, ctx: ctx)
            }

            drawPageNumber(2, ctx: ctx)
        }
        return page
    }

    private func makeStoragePage(snapshot: ReportSnapshot) -> PDFPage {
        let page = DrawablePDFPage(size: CGSize(width: pageWidth, height: pageHeight))
        page.draw { [self] ctx in
            drawPageBackground(ctx)
            var y = pageHeight - margin

            y = drawSectionHeader("Storage & Battery", y: y, ctx: ctx)

            let diskUsedGB = snapshot.diskTotalGB - snapshot.diskFreeGB
            let diskPct = snapshot.diskTotalGB > 0 ? diskUsedGB / snapshot.diskTotalGB : 0
            y = drawRow(label: "Disk Used",     value: String(format: "%.1f GB (%.0f%%)", diskUsedGB, diskPct * 100), y: y, ctx: ctx)
            y = drawRow(label: "Disk Free",     value: String(format: "%.1f GB", snapshot.diskFreeGB), y: y, ctx: ctx)
            y = drawRow(label: "Junk Size",     value: ByteCountFormatter.string(fromByteCount: snapshot.junkBytes, countStyle: .file), y: y, ctx: ctx)

            y -= 20
            y = drawSectionHeader("Battery Details", y: y, ctx: ctx)
            y = drawRow(label: "Charge Level",  value: "\(snapshot.batteryPercent)%", y: y, ctx: ctx)
            y = drawRow(label: "Cycle Count",   value: "\(snapshot.batteryCycles)", y: y, ctx: ctx)
            y = drawRow(label: "Battery Health",value: String(format: "%.0f%%", snapshot.batteryHealth * 100), y: y, ctx: ctx)

            drawPageNumber(3, ctx: ctx)
        }
        return page
    }

    private func makeAlertsPage(snapshot: ReportSnapshot) -> PDFPage {
        let page = DrawablePDFPage(size: CGSize(width: pageWidth, height: pageHeight))
        page.draw { [self] ctx in
            drawPageBackground(ctx)
            var y = pageHeight - margin

            y = drawSectionHeader("Alert History (last \(min(snapshot.alertEntries.count, 20)))", y: y, ctx: ctx)

            if snapshot.alertEntries.isEmpty {
                drawText("No alerts recorded — system running smoothly.",
                         at: CGPoint(x: margin, y: y - 30),
                         font: .systemFont(ofSize: 12),
                         color: CGColor(gray: 0.55, alpha: 1),
                         maxWidth: pageWidth - margin * 2, ctx: ctx)
            } else {
                for entry in snapshot.alertEntries.prefix(20) {
                    let dateStr = DateFormatter.localizedString(from: entry.date,
                                                               dateStyle: .short, timeStyle: .short)
                    y = drawRow(label: "\(dateStr)  \(entry.title)", value: "", y: y, ctx: ctx)
                    if y < margin + 60 { break }
                }
            }

            drawPageNumber(4, ctx: ctx)
        }
        return page
    }

    // MARK: - Drawing helpers

    private func drawPageBackground(_ ctx: CGContext) {
        ctx.setFillColor(CGColor(red: 0.031, green: 0.047, blue: 0.078, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
    }

    @discardableResult
    private func drawSectionHeader(_ title: String, y: CGFloat, ctx: CGContext) -> CGFloat {
        drawText(title,
                 at: CGPoint(x: margin, y: y - 28),
                 font: .systemFont(ofSize: 16, weight: .semibold),
                 color: CGColor(red: 0.310, green: 0.486, blue: 1.0, alpha: 1),
                 maxWidth: pageWidth - margin * 2, ctx: ctx)
        // Divider line
        ctx.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: margin, y: y - 36))
        ctx.addLine(to: CGPoint(x: pageWidth - margin, y: y - 36))
        ctx.strokePath()
        return y - 50
    }

    @discardableResult
    private func drawRow(label: String, value: String, y: CGFloat, ctx: CGContext) -> CGFloat {
        drawText(label,
                 at: CGPoint(x: margin, y: y - 18),
                 font: .systemFont(ofSize: 11),
                 color: CGColor(gray: 0.65, alpha: 1),
                 maxWidth: 240, ctx: ctx)
        if !value.isEmpty {
            drawText(value,
                     at: CGPoint(x: margin + 260, y: y - 18),
                     font: .systemFont(ofSize: 11, weight: .medium),
                     color: .white,
                     maxWidth: pageWidth - margin - 260 - margin, ctx: ctx)
        }
        return y - 26
    }

    private func drawPageNumber(_ n: Int, ctx: CGContext) {
        drawText("Page \(n) of 4",
                 at: CGPoint(x: pageWidth - margin - 60, y: 24),
                 font: .systemFont(ofSize: 9),
                 color: CGColor(gray: 0.35, alpha: 1),
                 maxWidth: 70, ctx: ctx)
    }

    private func drawText(
        _ text: String,
        at point: CGPoint,
        font: NSFont,
        color: CGColor,
        maxWidth: CGFloat,
        ctx: CGContext
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, attrStr.length),
            nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            nil
        )
        let path = CGPath(rect: CGRect(origin: point, size: size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: point.y * 2 + size.height)
        ctx.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}

// MARK: - DrawablePDFPage

/// A PDFPage subclass that draws via a callback into a CGContext.
private final class DrawablePDFPage: PDFPage {
    private let pageSize: CGSize
    private var drawCallback: ((CGContext) -> Void)?

    init(size: CGSize) {
        self.pageSize = size
        super.init()
    }

    func draw(using block: @escaping (CGContext) -> Void) {
        self.drawCallback = block
    }

    override func bounds(for box: PDFDisplayBox) -> CGRect {
        CGRect(origin: .zero, size: pageSize)
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        drawCallback?(context)
    }
}
