import AppKit
import Darwin
import IOKit

// MARK: - Constants & Utilities

private let gib = 1_073_741_824.0
private let mib = 1_048_576.0
private let kib = 1_024.0

private func formatBytes(_ bytes: Double) -> String {
    if bytes >= gib {
        return String(format: "%.1f GiB", bytes / gib)
    } else if bytes >= mib {
        return String(format: "%.1f MiB", bytes / mib)
    } else if bytes >= kib {
        return String(format: "%.0f KiB", bytes / kib)
    } else {
        return String(format: "%.0f B", bytes)
    }
}

private func formatRate(_ bytesPerSec: Double) -> String {
    if bytesPerSec >= mib {
        return String(format: "%.1f MiB/s", bytesPerSec / mib)
    } else if bytesPerSec >= kib {
        return String(format: "%.0f KiB/s", bytesPerSec / kib)
    } else {
        return "0 KiB/s"
    }
}

private enum MenuBarText {
    // Stable width even as values cross 9/10/100%, or a sensor is unavailable.
    static func percent(_ value: Double?) -> String {
        guard let value = value, value.isFinite, value >= 0 else { return "   —" }
        return String(format: "%3.0f%%", min(100, value))
    }

    static func make(cpu: Double?, gpu: Double?, ram: Double?, severity: Int) -> String {
        let alert = severity == 2 ? "■" : (severity == 1 ? "▲" : " ")
        return "CPU \(percent(cpu)) · GPU \(percent(gpu)) · RAM \(percent(ram)) \(alert)"
    }

    // Measure worst-case text at startup and reserve that width for the whole
    // session. The reserved item never resizes when percentages or alerts change.
    // A 16pt buffer covers the native NSStatusBarButton text insets.
    static let fixedWidth: CGFloat = {
        let cases = [
            styled(cpu: 100, gpu: 100, ram: 100, severity: 2),
            styled(cpu: nil, gpu: nil, ram: nil, severity: 1),
            styled(cpu: 8, gpu: 0, ram: 69, severity: 0)
        ]
        let maximumTextWidth = cases.map { $0.size().width }.max() ?? 0
        return max(CGFloat(234), ceil(maximumTextWidth + 16))
    }()

    // Colored status text is deliberately subtle: small metric dots and
    // matching numbers, neutral labels. Names stay visible without color,
    // including for accessibility and monochrome appearances.
    static func styled(cpu: Double?, gpu: Double?, ram: Double?, severity: Int) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let dotFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

        func append(_ string: String, font: NSFont, color: NSColor) {
            output.append(NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: color
            ]))
        }

        let metrics: [(String, Double?, NSColor)] = [
            ("CPU", cpu, .systemBlue),
            ("GPU", gpu, .systemPurple),
            ("RAM", ram, severity == 2 ? .systemRed : (severity == 1 ? .systemOrange : .systemGreen))
        ]
        for (index, metric) in metrics.enumerated() {
            let (name, value, color) = metric
            if index > 0 {
                append("  ", font: labelFont, color: .secondaryLabelColor)
            }
            let available = value.map { $0.isFinite && $0 >= 0 } ?? false
            append("●", font: dotFont, color: available ? color : .tertiaryLabelColor)
            append(" \(name) ", font: labelFont, color: .secondaryLabelColor)
            append(percent(value), font: valueFont,
                   color: available ? color : .secondaryLabelColor)
        }

        // Reserve alert space even when memory pressure is normal, preventing
        // all neighboring menu bar icons from shifting as the state changes.
        let glyph = severity == 2 ? "■" : (severity == 1 ? "▲" : " ")
        let alertColor: NSColor = severity == 2 ? .systemRed : .systemOrange
        append(" \(glyph)", font: dotFont, color: alertColor)
        return output
    }
}

private func cleanProcessName(_ raw: String) -> String {
    var name = raw
    if let range = name.range(of: " Helper") {
        name = String(name[..<range.lowerBound])
    }
    if let range = name.range(of: " (") {
        name = String(name[..<range.lowerBound])
    }
    return name
}

private func thermalStatus() -> (text: String, color: NSColor) {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:
        return ("Nominale", .systemGreen)
    case .fair:
        return ("Moderato", .systemYellow)
    case .serious:
        return ("Elevato (strozzamento)", .systemOrange)
    case .critical:
        return ("Critico", .systemRed)
    @unknown default:
        return ("Non disp.", .secondaryLabelColor)
    }
}

// MARK: - Memory health: sustained conditions, not swap capacity

struct MemoryHealthAssessment {
    let status: String
    let detail: String
    let severity: Int  // 0 = normal, 1 = warning, 2 = critical
}

private enum MemoryHealthAnalyzer {
    // Caller samples every 2s; windows are bounded to the latest 60s.
    // Brief bursts remain visible in the graphs without causing an alert.
    static func assess(pressureLevels: [Int], swapRates: [Double]) -> MemoryHealthAssessment {
        let current = pressureLevels.last ?? 0
        let redSeconds = pressureLevels.reversed().prefix(while: { $0 == 4 }).count * 2
        let elevatedSeconds = pressureLevels.reversed().prefix(while: { $0 == 2 || $0 == 4 }).count * 2
        let heavySwapSeconds = swapRates.reversed().prefix(while: { $0 >= 5.0 * mib }).count * 2

        if redSeconds >= 6 {
            return MemoryHealthAssessment(status: "Pressione critica persistente", detail: "Critica da almeno \(redSeconds)s. Riduci i carichi di memoria.", severity: 2)
        }
        if heavySwapSeconds >= 20 {
            return MemoryHealthAssessment(status: "Swap I/O intensa", detail: "Letture/scritture elevate da almeno \(heavySwapSeconds)s.", severity: 1)
        }
        if elevatedSeconds >= 30 {
            return MemoryHealthAssessment(status: "Pressione elevata persistente", detail: "Pressione elevata da almeno \(elevatedSeconds)s.", severity: 1)
        }
        if current == 4 || current == 2 {
            return MemoryHealthAssessment(status: "Pressione da osservare", detail: "Picco recente: nessun allarme persistente.", severity: 0)
        }
        if current != 1 {
            return MemoryHealthAssessment(status: "Pressione non disponibile", detail: "Stato non riconosciuto o lettura non riuscita.", severity: 0)
        }
        return MemoryHealthAssessment(status: "Memoria stabile", detail: "Nessun segnale persistente di difficoltà.", severity: 0)
    }
}

// MARK: - GPU Sampler

// Read-only, unprivileged GPU statistics exposed by macOS graphics drivers.
// GPU core load is a device-level percentage; core counts are metadata, not
// individual GPU-core utilization counters.
struct GPUStatistics {
    let utilization: Double?
    let renderer: Double?
    let tiler: Double?
    let memoryInUse: Double?
    let memoryAllocated: Double?
}

enum GPUStatisticsParser {
    private static func number(_ value: Any?) -> Double? {
        let parsed: Double
        if let value = value as? NSNumber {
            parsed = value.doubleValue
        } else if let value = value as? String,
                  let n = Double(value.replacingOccurrences(of: "%", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)) {
            parsed = n
        } else {
            return nil
        }
        return parsed.isFinite && parsed >= 0 ? parsed : nil
    }

    private static func percentage(_ keys: [String], from stats: [String: Any]) -> Double? {
        for key in keys {
            if let value = number(stats[key]), value <= 100 { return value }
        }
        return nil
    }

    private static func bytes(_ keys: [String], from stats: [String: Any]) -> Double? {
        for key in keys {
            if let value = number(stats[key]) { return value }
        }
        return nil
    }

    static func parse(_ stats: [String: Any]) -> GPUStatistics {
        GPUStatistics(
            utilization: percentage([
                "Device Utilization %", "GPU Activity(%)", "GPU Activity %",
                "GPU Utilization %", "GPU Busy %"
            ], from: stats),
            renderer: percentage(["Renderer Utilization %"], from: stats),
            tiler: percentage(["Tiler Utilization %"], from: stats),
            memoryInUse: bytes(["In use system memory", "In Use System Memory"], from: stats),
            memoryAllocated: bytes(["Alloc system memory", "Allocated system memory"], from: stats)
        )
    }
}

struct GPUDeviceSample {
    let id: UInt64
    let utilization: Double?
    let renderer: Double?
    let tiler: Double?
    let memoryInUse: Double?
    let memoryAllocated: Double?
    let coreCount: Int?
}

enum GPUReader {
    // Prefer AGX on Apple Silicon. Using *either* driver class (rather than
    // combining their results) avoids double-counting the same device.
    static func snapshot() -> [GPUDeviceSample] {
        let agx = readDevices(driverClass: "AGXAccelerator")
        return agx.isEmpty ? readDevices(driverClass: "IOAccelerator") : agx
    }

    private static func readDevices(driverClass: String) -> [GPUDeviceSample] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(driverClass),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [GPUDeviceSample] = []
        var seen = Set<UInt64>()
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  !seen.contains(id) else { continue }
            seen.insert(id)

            guard let raw = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            let stats = GPUStatisticsParser.parse(raw)
            guard stats.utilization != nil || stats.renderer != nil || stats.tiler != nil ||
                    stats.memoryInUse != nil || stats.memoryAllocated != nil else { continue }

            let coreProperty = IORegistryEntryCreateCFProperty(
                service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue()
            let reportedCores = (coreProperty as? NSNumber)?.intValue
            devices.append(GPUDeviceSample(
                id: id,
                utilization: stats.utilization,
                renderer: stats.renderer,
                tiler: stats.tiler,
                memoryInUse: stats.memoryInUse,
                memoryAllocated: stats.memoryAllocated,
                coreCount: reportedCores.flatMap { $0 > 0 ? $0 : nil }
            ))
        }
        return devices.sorted { $0.id < $1.id }
    }
}

// MARK: - ProgressTrackView (CALayer-based, zero constraint recreation)

final class ProgressTrackView: NSView {
    private let fillLayer = CALayer()
    var fraction: Double = 0.0 {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateFill()
            CATransaction.commit()
        }
    }
    var fillColor: NSColor = .systemBlue {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.backgroundColor = fillColor.cgColor
            CATransaction.commit()
        }
    }

    init(height: CGFloat = 7) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = height / 2.0
        layer?.masksToBounds = true

        fillLayer.cornerRadius = height / 2.0
        fillLayer.backgroundColor = fillColor.cgColor
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateFill()
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        fillLayer.backgroundColor = fillColor.cgColor
    }

    private func updateFill() {
        let clamped = CGFloat(max(0.0, min(1.0, fraction.isNaN ? 0.0 : fraction)))
        fillLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
        fillLayer.isHidden = clamped <= 0.001
    }
}

// MARK: - 60-second pressure strip (green/yellow/red, not a percentage)

final class PressureStripView: NSView {
    var levels: [Int] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let recent = Array(levels.suffix(30))
        let count = 30
        let spacing: CGFloat = 2
        let itemWidth = max(1, (bounds.width - CGFloat(count - 1) * spacing) / CGFloat(count))
        guard itemWidth > 0, bounds.height > 0 else { return }
        let offset = count - recent.count

        for (index, level) in recent.enumerated() {
            let x = CGFloat(offset + index) * (itemWidth + spacing)
            let color: NSColor
            switch level {
            case 4: color = .systemRed
            case 2: color = .systemYellow
            case 1: color = .systemGreen
            default: color = .quaternaryLabelColor
            }
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: itemWidth, height: bounds.height), xRadius: 2, yRadius: 2).fill()
        }
    }
}

// MARK: - MetricBarView

final class MetricBarView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let trackView: ProgressTrackView

    init(title: String, valueText: String, fraction: Double, color: NSColor, height: CGFloat = 7) {
        self.trackView = ProgressTrackView(height: height)
        super.init(frame: .zero)
        setup(title: title, valueText: valueText, fraction: fraction, color: color, height: height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup(title: String, valueText: String, fraction: Double, color: NSColor, height: CGFloat) {
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .left
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        valueLabel.stringValue = valueText
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.isBezeled = false
        valueLabel.drawsBackground = false
        valueLabel.isEditable = false
        valueLabel.isSelectable = false
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        trackView.fraction = fraction
        trackView.fillColor = color

        let labels = NSStackView(views: [titleLabel, valueLabel])
        labels.orientation = .horizontal
        labels.distribution = .fill

        addSubview(labels)
        addSubview(trackView)

        labels.translatesAutoresizingMaskIntoConstraints = false
        trackView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(equalTo: topAnchor),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor),

            trackView.topAnchor.constraint(equalTo: labels.bottomAnchor, constant: 3),
            trackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackView.heightAnchor.constraint(equalToConstant: height),
            trackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func update(title: String? = nil, valueText: String, fraction: Double, color: NSColor? = nil) {
        if let title = title { titleLabel.stringValue = title }
        valueLabel.stringValue = valueText
        trackView.fraction = fraction
        if let color = color { trackView.fillColor = color }
    }
}

// MARK: - SparklineView (Ultimi 60 secondi)

final class SparklineView: NSView {
    var values: [Double] = [] {
        didSet { needsDisplay = true }
    }
    var strokeColor: NSColor = .systemBlue
    var fillColor: NSColor = .systemBlue.withAlphaComponent(0.18)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let w = bounds.width
        let h = bounds.height
        guard w > 10, h > 10 else { return }

        // Subtle mid-line at 50%
        let gridPath = NSBezierPath()
        let yMid = round(h * 0.5) + 0.5
        gridPath.move(to: NSPoint(x: 0, y: yMid))
        gridPath.line(to: NSPoint(x: w, y: yMid))
        NSColor.quaternaryLabelColor.setStroke()
        gridPath.lineWidth = 0.5
        gridPath.stroke()

        guard values.count > 1 else { return }

        let maxPoints = 30
        let step = w / CGFloat(maxPoints - 1)
        let startIndex = max(0, maxPoints - values.count)

        let path = NSBezierPath()
        let fillPath = NSBezierPath()

        let firstX = CGFloat(startIndex) * step
        let firstClamped = max(0.0, min(100.0, values[0]))
        let firstY = (CGFloat(firstClamped) / 100.0) * (h - 4) + 2
        let firstPt = NSPoint(x: firstX, y: firstY)

        fillPath.move(to: NSPoint(x: firstX, y: 0))
        fillPath.line(to: firstPt)
        path.move(to: firstPt)

        for i in 1..<values.count {
            let clamped = max(0.0, min(100.0, values[i]))
            let x = CGFloat(startIndex + i) * step
            let y = (CGFloat(clamped) / 100.0) * (h - 4) + 2
            let pt = NSPoint(x: x, y: y)
            path.line(to: pt)
            fillPath.line(to: pt)
        }

        let lastX = CGFloat(startIndex + values.count - 1) * step
        fillPath.line(to: NSPoint(x: lastX, y: 0))
        fillPath.close()

        fillColor.setFill()
        fillPath.fill()

        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        strokeColor.setStroke()
        path.stroke()
    }
}

// MARK: - Process sampling (deterministic parsing, testable independently)

struct ProcessSample {
    let pid: pid_t
    let cpu: Double
    let rss: Double
    let comm: String
}

private enum ProcessSnapshotParser {
    // Separate columns with header suppression; avoid relying on a locale-dependent header.
    static let arguments = ["-A", "-o", "pid=", "-o", "%cpu=", "-o", "rss=", "-o", "comm="]

    static func parse(_ output: String) -> [ProcessSample] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 4,
                  let pid = pid_t(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = Double(fields[2]),
                  cpu.isFinite, rssKB.isFinite, rssKB >= 0 else { return nil }
            return ProcessSample(pid: pid, cpu: cpu, rss: rssKB * 1024, comm: String(fields[3]))
        }
    }
}

// MARK: - Process presentation: accurate per-PID data, optional app grouping

private enum ProcessIdentity {
    // The first .app is the outer application (Chrome Helpers have nested bundles).
    static func bundleRoot(_ raw: String) -> String? {
        guard raw.hasPrefix("/"),
              let range = raw.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return String(raw[..<range.lowerBound]) + ".app"
    }

    static func executableName(_ raw: String) -> String {
        let name = raw.hasPrefix("/") ? URL(fileURLWithPath: raw).lastPathComponent : raw
        return name.isEmpty ? "Processo sconosciuto" : name
    }

    static func applicationName(_ raw: String) -> String {
        if let root = bundleRoot(raw) {
            return URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent
        }
        return cleanProcessName(executableName(raw))
    }
}

struct ProcessDisplayItem {
    let key: String
    let name: String
    let subtitle: String
    let cpu: Double
    let rss: Double
    let members: [ProcessSample]
    let appPath: String?
    let isGroup: Bool
    var representativePID: pid_t { members.first?.pid ?? 0 }
}

private enum ProcessRanker {
    static func make(_ items: [ProcessSample], groupApps: Bool, sortCPU: Bool) -> [ProcessDisplayItem] {
        var buckets: [String: [ProcessSample]] = [:]
        for item in items {
            // Do not merge unrelated CLI tools just because they both run "python".
            let groupKey = groupApps ? ProcessIdentity.bundleRoot(item.comm).map { "app:\($0)" } : nil
            buckets[groupKey ?? "pid:\(item.pid)", default: []].append(item)
        }
        let rows = buckets.map { key, members -> ProcessDisplayItem in
            let members = members.sorted {
                if $0.cpu == $1.cpu { return $0.pid < $1.pid }
                return $0.cpu > $1.cpu
            }
            let first = members[0]
            let appPath = ProcessIdentity.bundleRoot(first.comm)
            let aggregated = members.count > 1
            let title = groupApps ? ProcessIdentity.applicationName(first.comm)
                                  : ProcessIdentity.executableName(first.comm)
            let subtitle = aggregated ? "\(members.count) processi · RSS stimata"
                                      : "PID \(first.pid)"
            return ProcessDisplayItem(key: key, name: title, subtitle: subtitle,
                                      cpu: members.reduce(0) { $0 + $1.cpu },
                                      rss: members.reduce(0) { $0 + $1.rss },
                                      members: members, appPath: appPath, isGroup: aggregated)
        }
        return rows.sorted {
            let lhs = sortCPU ? $0.cpu : $0.rss
            let rhs = sortCPU ? $1.cpu : $1.rss
            if lhs == rhs { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return lhs > rhs
        }
    }
}

// MARK: - Top processes: single full-width table, expandable details

final class TopProcessRowView: NSStackView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let cpuLabel = NSTextField(labelWithString: "—")
    private let ramLabel = NSTextField(labelWithString: "—")
    private let chevron = NSTextField(labelWithString: "⌄")
    private let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private let activityButton = NSButton(title: "Apri Monitoraggio Attività", target: nil, action: nil)
    private let detailsStack = NSStackView()
    var onExpand: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        spacing = 5
        alignment = .width

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18)
        ])
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.font = .systemFont(ofSize: 9.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .left
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The name stack occupies ALL remaining row width. Otherwise its
        // intrinsic width can shrink to a few glyphs and drift toward CPU.
        let nameColumn = NSStackView(views: [titleLabel, subtitleLabel])
        nameColumn.orientation = .vertical
        nameColumn.alignment = .width
        nameColumn.spacing = 0
        nameColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (label, width) in [(cpuLabel, 63.0), (ramLabel, 87.0)] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        chevron.font = .systemFont(ofSize: 11, weight: .medium)
        chevron.textColor = .tertiaryLabelColor
        chevron.alignment = .right
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let header = NSStackView(views: [iconView, nameColumn, cpuLabel, ramLabel, chevron])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.distribution = .fill
        header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(expandClicked)))
        addArrangedSubview(header)
        // Pin the row's content to both edges. In a vertical NSStackView,
        // an arranged row's intrinsic width is NOT necessarily the table width.
        header.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        header.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        nameColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailsLabel.font = .systemFont(ofSize: 10.5)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.isSelectable = true
        detailsLabel.lineBreakMode = .byWordWrapping
        detailsLabel.maximumNumberOfLines = 7
        detailsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activityButton.bezelStyle = .recessed
        activityButton.font = .systemFont(ofSize: 10)
        activityButton.target = self
        activityButton.action = #selector(openActivityMonitor)

        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 5
        detailsStack.addArrangedSubview(detailsLabel)
        detailsStack.addArrangedSubview(activityButton)
        detailsLabel.leadingAnchor.constraint(equalTo: detailsStack.leadingAnchor).isActive = true
        detailsLabel.trailingAnchor.constraint(equalTo: detailsStack.trailingAnchor).isActive = true
        detailsStack.isHidden = true
        addArrangedSubview(detailsStack)
        detailsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26).isActive = true
        detailsStack.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: ProcessDisplayItem, expanded: Bool, command: String?) {
        titleLabel.stringValue = item.name
        subtitleLabel.stringValue = item.subtitle
        cpuLabel.stringValue = String(format: item.cpu < 1 && item.cpu > 0 ? "%.1f%%" : "%.0f%%", item.cpu)
        ramLabel.stringValue = formatBytes(item.rss)
        cpuLabel.textColor = .systemBlue
        ramLabel.textColor = .systemGreen
        chevron.stringValue = expanded ? "⌃" : "⌄"
        detailsStack.isHidden = !expanded
        iconView.image = item.appPath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Processo")
        toolTip = "\(item.name) · CPU: \(cpuLabel.stringValue) · RAM RSS: \(ramLabel.stringValue)"
        if expanded {
            let pids = item.members.map { String($0.pid) }.joined(separator: ", ")
            let executable = item.members.first?.comm ?? "Non disponibile"
            let note = item.isGroup
                ? "CPU: somma dei processi (100% = un core). RSS aggregata: stima, include memoria condivisa."
                : "CPU: 100% = un core; RSS: memoria residente stimata."
            let exactCommand = command.map { "Comando: \($0)\n" } ?? "Comando: caricamento…\n"
            detailsLabel.stringValue = "PID: \(pids)\nEseguibile: \(executable)\n\(exactCommand)\(note)"
            detailsLabel.toolTip = detailsLabel.stringValue
        }
    }

    @objc private func expandClicked() { onExpand?() }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

final class TopProcessesSectionView: NSStackView {
    private let headerLabel = NSTextField(labelWithString: "TOP PROCESSI")
    private let helpLabel = NSTextField(labelWithString: "CPU: 100% = 1 core · RAM: RSS stimata")
    private let statusLabel = NSTextField(labelWithString: "Caricamento processi…")
    private let sortSelector = NSSegmentedControl(labels: ["CPU", "RAM"], trackingMode: .selectOne, target: nil, action: nil)
    private let groupSelector = NSSegmentedControl(labels: ["App", "Processi"], trackingMode: .selectOne, target: nil, action: nil)
    private let headings = NSStackView()
    private let rowsStack = NSStackView()
    private let moreButton = NSButton(title: "Mostra altri", target: nil, action: nil)
    private var rowViews: [TopProcessRowView] = []
    private var samples: [ProcessSample] = []
    private var selectedKey: String?
    private var expandedList = false
    private var commandsByPID: [pid_t: String] = [:]
    private var errorMessage: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        spacing = 8
        alignment = .width

        headerLabel.font = .systemFont(ofSize: 11, weight: .bold)
        headerLabel.textColor = .secondaryLabelColor
        helpLabel.font = .systemFont(ofSize: 10)
        helpLabel.textColor = .tertiaryLabelColor

        sortSelector.selectedSegment = 0
        groupSelector.selectedSegment = 0
        for selector in [sortSelector, groupSelector] {
            selector.controlSize = .small
            selector.font = .systemFont(ofSize: 10)
            selector.target = self
            selector.action = #selector(selectionChanged)
        }
        let controls = NSStackView(views: [sortSelector, groupSelector])
        controls.orientation = .horizontal
        controls.spacing = 8
        let titleRow = NSStackView(views: [headerLabel, controls])
        titleRow.orientation = .horizontal
        titleRow.distribution = .fill
        addArrangedSubview(titleRow)
        addArrangedSubview(helpLabel)

        let nameTitle = NSTextField(labelWithString: "APPLICAZIONE / PROCESSO")
        let cpuTitle = NSTextField(labelWithString: "CPU")
        let ramTitle = NSTextField(labelWithString: "RAM (RSS)")
        let arrow = NSTextField(labelWithString: "")
        for label in [nameTitle, cpuTitle, ramTitle] {
            label.font = .systemFont(ofSize: 9, weight: .medium)
            label.textColor = .tertiaryLabelColor
        }
        for (label, width) in [(cpuTitle, 63.0), (ramTitle, 87.0), (arrow, 12.0)] {
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        headings.addArrangedSubview(nameTitle)
        headings.addArrangedSubview(cpuTitle)
        headings.addArrangedSubview(ramTitle)
        headings.addArrangedSubview(arrow)
        headings.orientation = .horizontal
        headings.spacing = 8
        headings.distribution = .fill
        headings.edgeInsets = NSEdgeInsets(top: 0, left: 26, bottom: 0, right: 0)
        addArrangedSubview(headings)
        headings.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        headings.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        addArrangedSubview(statusLabel)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 10
        addArrangedSubview(rowsStack)
        // Expand the list to the full available panel width, independently
        // of each process name's intrinsic width.
        rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true

        moreButton.bezelStyle = .recessed
        moreButton.font = .systemFont(ofSize: 10.5)
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        addArrangedSubview(moreButton)
        moreButton.isHidden = true
        refresh()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(samples: [ProcessSample], error: String?) {
        self.samples = samples
        self.errorMessage = error
        // A previous PID may have exited. Do not hold stale command data forever.
        if commandsByPID.count > 100 { commandsByPID.removeAll() }
        refresh()
    }

    private func refresh() {
        let sorted = ProcessRanker.make(samples, groupApps: groupSelector.selectedSegment != 1,
                                        sortCPU: sortSelector.selectedSegment != 1)
        let visible = Array(sorted.prefix(expandedList ? 12 : 5))
        statusLabel.isHidden = !visible.isEmpty
        statusLabel.stringValue = errorMessage ?? (samples.isEmpty ? "Nessun processo disponibile" : "")
        headings.isHidden = visible.isEmpty
        moreButton.isHidden = sorted.count <= 5
        moreButton.title = expandedList ? "Mostra meno" : "Mostra altri (\(min(12, sorted.count) - 5))"

        while rowViews.count < visible.count {
            let row = TopProcessRowView(frame: .zero)
            rowsStack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor).isActive = true
            rowViews.append(row)
        }
        for (index, row) in rowViews.enumerated() {
            row.isHidden = index >= visible.count
            guard index < visible.count else { continue }
            let entry = visible[index]
            let key = entry.key
            row.onExpand = { [weak self] in self?.toggleDetails(key: key, entry: entry) }
            row.configure(entry, expanded: selectedKey == key,
                          command: commandsByPID[entry.representativePID])
        }
    }

    private func toggleDetails(key: String, entry: ProcessDisplayItem) {
        selectedKey = selectedKey == key ? nil : key
        refresh()
        if selectedKey == key && commandsByPID[entry.representativePID] == nil {
            loadCommand(pid: entry.representativePID)
        }
    }

    // Only inspect a complete command when the user expands a row.
    // Keeps the six-second process sampling inexpensive.
    private func loadCommand(pid: pid_t) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-p", String(pid), "-o", "command="]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            let value: String
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                value = task.terminationStatus == 0
                    ? (String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Non disponibile")
                    : "Processo terminato"
            } catch {
                value = "Non disponibile"
            }
            DispatchQueue.main.async { [weak self] in
                self?.commandsByPID[pid] = String(value.prefix(1000))
                self?.refresh()
            }
        }
    }

    @objc private func selectionChanged() {
        selectedKey = nil
        expandedList = false
        refresh()
    }

    @objc private func moreClicked() {
        expandedList.toggle()
        selectedKey = nil
        refresh()
    }
}

// MARK: - LaunchAgent Manager (Robusto)

enum LaunchAgentManager {
    static var plistPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/com.user.menumeter.plist"
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func setEnabled(_ enable: Bool) {
        let dir = (plistPath as NSString).deletingLastPathComponent
        _ = try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if enable {
            let binaryPath = CommandLine.arguments[0].hasPrefix("/") ? CommandLine.arguments[0] : "/Users/\(NSUserName())/.local/bin/menumeter"
            let content = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.user.menumeter</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(binaryPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            do {
                try content.write(toFile: plistPath, atomically: true, encoding: .utf8)
                let task = Process()
                task.launchPath = "/bin/launchctl"
                task.arguments = ["load", "-w", plistPath]
                try? task.run()
            } catch {
                // write failed
            }
        } else {
            let task = Process()
            task.launchPath = "/bin/launchctl"
            task.arguments = ["unload", "-w", plistPath]
            try? task.run()
            _ = try? FileManager.default.removeItem(atPath: plistPath)
        }
    }
}

// MARK: - DashboardViewController

final class DashboardViewController: NSViewController {
    // CPU Section
    let cpuTitleLabel = NSTextField(labelWithString: "CPU")
    let cpuValueLabel = NSTextField(labelWithString: "0%")
    let coresToggleButton = NSButton(title: "▾ 12 Core", target: nil, action: nil)
    let cpuSparklineView = SparklineView()
    let cpuSparklineCaption = NSTextField(labelWithString: "Ultimi 60s")
    let coresStack = NSStackView()
    var coreBarViews: [MetricBarView] = []
    var coresExpanded: Bool = false

    // GPU sits below CPU, preserving two readable columns.
    let gpuTitleLabel = NSTextField(labelWithString: "GPU")
    let gpuValueLabel = NSTextField(labelWithString: "—")
    let gpuSparklineView = SparklineView()
    let gpuSparklineCaption = NSTextField(labelWithString: "GPU · ULTIMI 60s")
    let gpuInfoLabel = NSTextField(labelWithString: "Rilevamento GPU…")
    let gpuMemoryLabel = NSTextField(labelWithString: "")
    let gpuAllocatedLabel = NSTextField(labelWithString: "")
    let gpuRendererBar = MetricBarView(title: "Renderer", valueText: "—", fraction: 0, color: .systemPurple)
    let gpuTilerBar = MetricBarView(title: "Tiler", valueText: "—", fraction: 0, color: .systemIndigo)
    let gpuDevicesStack = NSStackView()
    var gpuDeviceBars: [MetricBarView] = []

    // RAM Section
    let ramTitleLabel = NSTextField(labelWithString: "RAM")
    let ramValueLabel = NSTextField(labelWithString: "0 / 0 GiB")
    let ramSparklineView = SparklineView()
    let ramSparklineCaption = NSTextField(labelWithString: "Ultimi 60s")

    let pressureTitleLabel = NSTextField(labelWithString: "Pressione memoria")
    let pressureBadgeLabel = NSTextField(labelWithString: "● Normale")
    let pressureHistoryLabel = NSTextField(labelWithString: "PRESSIONE · ULTIMI 60s")
    let pressureHistoryView = PressureStripView()
    let healthStatusLabel = NSTextField(labelWithString: "● Memoria stabile")
    let healthDetailLabel = NSTextField(labelWithString: "Nessun allarme persistente")

    let activeBar = MetricBarView(title: "Attiva", valueText: "0 GiB", fraction: 0, color: .systemCyan)
    let wiredBar = MetricBarView(title: "Cablata", valueText: "0 GiB", fraction: 0, color: .systemIndigo)
    let compressedBar = MetricBarView(title: "Compressa", valueText: "0 GiB", fraction: 0, color: .systemPurple)
    let freeBar = MetricBarView(title: "Libera", valueText: "0 GiB", fraction: 0, color: .systemGray)
    let swapUsageTitle = NSTextField(labelWithString: "Swap su disco")
    let swapUsageValue = NSTextField(labelWithString: "Non disponibile")
    let swapSparklineView = SparklineView()
    let swapSparklineCaption = NSTextField(labelWithString: "I/O ultimi 60s")

    let swapActivityTitle = NSTextField(labelWithString: "I/O")
    let swapActivityValue = NSTextField(labelWithString: "↓ 0 KiB/s · ↑ 0 KiB/s")

    let topProcesses = TopProcessesSectionView(frame: .zero)

    // Footer
    let thermalLabel = NSTextField(labelWithString: "Stato termico: Nominale")
    let copyDiagButton = NSButton(title: "Copia diagnostica", target: nil, action: nil)
    let showProcessesButton = NSButton(title: "Processi ↓", target: nil, action: nil)

    var onQuit: (() -> Void)?
    var onToggleCores: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layer?.cornerRadius = 12

        let cpuColumn = buildCPUColumn()
        let ramColumn = buildRAMColumn()

        let columns = NSStackView(views: [cpuColumn, ramColumn])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 20

        // One scrollable document: resource columns, then full-width process table.
        // The footer stays pinned outside the scrollable document.
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        let processDivider = NSBox()
        processDivider.boxType = .separator
        let document = NSStackView(views: [columns, processDivider, topProcesses])
        document.orientation = .vertical
        document.alignment = .width
        document.spacing = 12
        body.addSubview(document)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: body.topAnchor),
            document.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            document.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
        let bodyScrollView = NSScrollView()
        bodyScrollView.drawsBackground = false
        bodyScrollView.borderType = .noBorder
        bodyScrollView.hasVerticalScroller = true
        bodyScrollView.autohidesScrollers = true
        bodyScrollView.verticalScrollElasticity = .allowed
        bodyScrollView.documentView = body

        let separator = NSBox()
        separator.boxType = .separator

        let footerStack = buildFooter()

        root.addSubview(bodyScrollView)
        root.addSubview(separator)
        root.addSubview(footerStack)

        bodyScrollView.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 540),

            bodyScrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            bodyScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            bodyScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            bodyScrollView.heightAnchor.constraint(equalToConstant: 430),
            body.widthAnchor.constraint(equalTo: bodyScrollView.contentView.widthAnchor),

            separator.topAnchor.constraint(equalTo: bodyScrollView.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            footerStack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        self.view = root
    }

    private func buildCPUColumn() -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 6
        column.alignment = .leading

        // Header: "CPU", "24%", "▾ 12 Core"
        cpuTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        cpuTitleLabel.textColor = .labelColor

        cpuValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        cpuValueLabel.textColor = .systemBlue
        cpuValueLabel.alignment = .right

        coresToggleButton.bezelStyle = .inline
        coresToggleButton.font = .systemFont(ofSize: 10.5, weight: .medium)
        coresToggleButton.target = self
        coresToggleButton.action = #selector(coresToggleClicked)

        let headerLeft = NSStackView(views: [cpuTitleLabel, coresToggleButton])
        headerLeft.orientation = .horizontal
        headerLeft.spacing = 8

        let headerStack = NSStackView(views: [headerLeft, cpuValueLabel])
        headerStack.orientation = .horizontal
        headerStack.distribution = .fill

        column.addArrangedSubview(headerStack)
        headerStack.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        headerStack.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        // Sparkline Caption + View
        cpuSparklineCaption.font = .systemFont(ofSize: 10, weight: .medium)
        cpuSparklineCaption.textColor = .tertiaryLabelColor
        column.addArrangedSubview(cpuSparklineCaption)

        cpuSparklineView.translatesAutoresizingMaskIntoConstraints = false
        cpuSparklineView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        column.addArrangedSubview(cpuSparklineView)
        cpuSparklineView.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        cpuSparklineView.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        // Collapsible Cores Stack
        coresStack.orientation = .vertical
        coresStack.spacing = 5
        coresStack.alignment = .leading
        coresStack.isHidden = true
        column.addArrangedSubview(coresStack)
        coresStack.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        coresStack.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        // GPU section: compact history + optional driver-level details.
        let gpuHeader = NSStackView(views: [gpuTitleLabel, gpuValueLabel])
        gpuHeader.orientation = .horizontal
        gpuHeader.distribution = .fill
        gpuTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        gpuValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        gpuValueLabel.textColor = .systemPurple
        gpuValueLabel.alignment = .right
        column.addArrangedSubview(gpuHeader)
        gpuHeader.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        gpuHeader.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        gpuSparklineCaption.font = .systemFont(ofSize: 10, weight: .medium)
        gpuSparklineCaption.textColor = .tertiaryLabelColor
        column.addArrangedSubview(gpuSparklineCaption)
        gpuSparklineView.strokeColor = .systemPurple
        gpuSparklineView.fillColor = NSColor.systemPurple.withAlphaComponent(0.18)
        gpuSparklineView.translatesAutoresizingMaskIntoConstraints = false
        gpuSparklineView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        column.addArrangedSubview(gpuSparklineView)
        gpuSparklineView.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        gpuSparklineView.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        for label in [gpuInfoLabel, gpuMemoryLabel, gpuAllocatedLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            column.addArrangedSubview(label)
        }
        gpuMemoryLabel.toolTip = "Memoria unificata già conteggiata nella RAM totale, non VRAM aggiuntiva."
        gpuAllocatedLabel.toolTip = "Memoria allocata dal driver GPU: può superare quella attivamente in uso."
        for bar in [gpuRendererBar, gpuTilerBar] {
            bar.isHidden = true
            column.addArrangedSubview(bar)
            bar.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
            bar.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        }
        gpuDevicesStack.orientation = .vertical
        gpuDevicesStack.alignment = .leading
        gpuDevicesStack.spacing = 5
        gpuDevicesStack.isHidden = true
        column.addArrangedSubview(gpuDevicesStack)
        gpuDevicesStack.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        gpuDevicesStack.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        return column
    }

    private func buildRAMColumn() -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 6
        column.alignment = .leading

        // Header: "RAM", "21.8 / 32.0 GiB (68%)"
        ramTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        ramTitleLabel.textColor = .labelColor

        ramValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        ramValueLabel.textColor = .systemGreen
        ramValueLabel.alignment = .right

        let headerStack = NSStackView(views: [ramTitleLabel, ramValueLabel])
        headerStack.orientation = .horizontal
        headerStack.distribution = .fill

        column.addArrangedSubview(headerStack)
        headerStack.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        headerStack.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        // RAM Sparkline Caption + View
        ramSparklineCaption.font = .systemFont(ofSize: 10, weight: .medium)
        ramSparklineCaption.textColor = .tertiaryLabelColor
        column.addArrangedSubview(ramSparklineCaption)

        ramSparklineView.strokeColor = .systemGreen
        ramSparklineView.fillColor = .systemGreen.withAlphaComponent(0.18)
        ramSparklineView.translatesAutoresizingMaskIntoConstraints = false
        ramSparklineView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        column.addArrangedSubview(ramSparklineView)
        ramSparklineView.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        ramSparklineView.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        // Memory Pressure Row
        pressureTitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        pressureTitleLabel.textColor = .labelColor

        pressureBadgeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        pressureBadgeLabel.textColor = .systemGreen
        pressureBadgeLabel.alignment = .right

        let pressureStack = NSStackView(views: [pressureTitleLabel, pressureBadgeLabel])
        pressureStack.orientation = .horizontal
        pressureStack.distribution = .fill

        column.addArrangedSubview(pressureStack)
        pressureStack.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        pressureStack.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        // Compact native pressure-state history (not a RAM usage percentage).
        pressureHistoryLabel.font = .systemFont(ofSize: 10, weight: .medium)
        pressureHistoryLabel.textColor = .tertiaryLabelColor
        column.addArrangedSubview(pressureHistoryLabel)

        pressureHistoryView.translatesAutoresizingMaskIntoConstraints = false
        pressureHistoryView.heightAnchor.constraint(equalToConstant: 8).isActive = true
        column.addArrangedSubview(pressureHistoryView)
        pressureHistoryView.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        pressureHistoryView.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        healthStatusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        healthStatusLabel.textColor = .systemGreen
        healthDetailLabel.font = .systemFont(ofSize: 10, weight: .regular)
        healthDetailLabel.textColor = .secondaryLabelColor
        healthDetailLabel.lineBreakMode = .byWordWrapping
        healthDetailLabel.maximumNumberOfLines = 2
        column.addArrangedSubview(healthStatusLabel)
        column.addArrangedSubview(healthDetailLabel)
        healthStatusLabel.toolTip = "Gli avvisi richiedono pressione critica per 6s, elevata per 30s oppure swap I/O >= 5 MiB/s per 20s."

        // RAM components are shown separately, not added together.
        for bar in [activeBar, wiredBar, compressedBar, freeBar] {
            column.addArrangedSubview(bar)
            bar.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
            bar.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        }

        // Occupied disk swap is an amount, not a percentage of a fixed capacity.
        swapUsageTitle.font = .systemFont(ofSize: 11.5, weight: .medium)
        swapUsageTitle.textColor = .secondaryLabelColor
        swapUsageValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        swapUsageValue.textColor = .secondaryLabelColor
        swapUsageValue.alignment = .right
        let swapUsageRow = NSStackView(views: [swapUsageTitle, swapUsageValue])
        swapUsageRow.orientation = .horizontal
        swapUsageRow.distribution = .fill
        swapUsageRow.toolTip = "La dimensione della swap allocata da macOS è dinamica, non un limite fisso. Contano soprattutto pressione memoria e I/O."
        column.addArrangedSubview(swapUsageRow)
        swapUsageRow.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        swapUsageRow.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        // Swap Activity Row
        swapActivityTitle.font = .systemFont(ofSize: 11.5, weight: .medium)
        swapActivityTitle.textColor = .secondaryLabelColor

        swapActivityValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        swapActivityValue.textColor = .secondaryLabelColor
        swapActivityValue.alignment = .right

        let swapActivityStack = NSStackView(views: [swapActivityTitle, swapActivityValue])
        swapActivityStack.orientation = .horizontal
        swapActivityStack.distribution = .fill

        column.addArrangedSubview(swapActivityStack)
        swapActivityStack.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        swapActivityStack.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        swapSparklineCaption.font = .systemFont(ofSize: 10, weight: .medium)
        swapSparklineCaption.textColor = .tertiaryLabelColor
        column.addArrangedSubview(swapSparklineCaption)
        swapSparklineView.strokeColor = .systemTeal
        swapSparklineView.fillColor = NSColor.systemTeal.withAlphaComponent(0.14)
        swapSparklineView.translatesAutoresizingMaskIntoConstraints = false
        swapSparklineView.heightAnchor.constraint(equalToConstant: 26).isActive = true
        column.addArrangedSubview(swapSparklineView)
        swapSparklineView.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        swapSparklineView.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        return column
    }

    private func buildFooter() -> NSStackView {
        // Line 1: Thermal State + Copy Diagnostics
        thermalLabel.font = .systemFont(ofSize: 11, weight: .medium)
        thermalLabel.textColor = .secondaryLabelColor
        thermalLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        copyDiagButton.title = "Copia diagnostica"
        copyDiagButton.bezelStyle = .recessed
        copyDiagButton.font = .systemFont(ofSize: 11)
        copyDiagButton.target = self
        copyDiagButton.action = #selector(copyDiagClicked)

        showProcessesButton.bezelStyle = .recessed
        showProcessesButton.font = .systemFont(ofSize: 11)
        showProcessesButton.target = self
        showProcessesButton.action = #selector(showProcessesClicked)

        let line1 = NSStackView(views: [thermalLabel, showProcessesButton, copyDiagButton])
        line1.orientation = .horizontal
        line1.distribution = .fill

        // Line 2: Version, Auto-start, Quit
        let appTitle = NSTextField(labelWithString: "MenuMeter v4.3")
        appTitle.font = .systemFont(ofSize: 11, weight: .medium)
        appTitle.textColor = .tertiaryLabelColor
        appTitle.isBezeled = false
        appTitle.drawsBackground = false
        appTitle.isEditable = false
        appTitle.isSelectable = false
        appTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let loginCheckbox = NSButton(checkboxWithTitle: "Avvia al login", target: self, action: #selector(loginCheckboxChanged(_:)))
        loginCheckbox.font = .systemFont(ofSize: 11)
        loginCheckbox.state = LaunchAgentManager.isInstalled ? .on : .off

        let quitButton = NSButton(title: "Esci", target: self, action: #selector(quitClicked))
        quitButton.bezelStyle = .rounded
        quitButton.font = .systemFont(ofSize: 11)

        let line2 = NSStackView(views: [appTitle, loginCheckbox, quitButton])
        line2.orientation = .horizontal
        line2.spacing = 10
        line2.distribution = .fill

        let footerStack = NSStackView(views: [line1, line2])
        footerStack.orientation = .vertical
        footerStack.spacing = 6
        footerStack.alignment = .width
        return footerStack
    }

    @objc private func coresToggleClicked() {
        coresExpanded.toggle()
        coresStack.isHidden = !coresExpanded
        let coreCount = coreBarViews.count
        coresToggleButton.title = coresExpanded ? "▴ Nascondi" : "▾ \(coreCount) Core"
        onToggleCores?()
    }

    @objc private func loginCheckboxChanged(_ sender: NSButton) {
        LaunchAgentManager.setEnabled(sender.state == .on)
    }

    @objc private func showProcessesClicked() {
        // The process table is below the resource charts in the scrollable pane.
        _ = topProcesses.scrollToVisible(topProcesses.bounds)
    }

    @objc private func copyDiagClicked() {
        onCopyDiagnostics?()
        copyDiagButton.title = "✓ Copiato!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyDiagButton.title = "Copia diagnostica"
        }
    }

    @objc private func quitClicked() {
        onQuit?()
    }

    func updateCPU(total: Double, history: [Double], cores: [Double], smoothedColor: NSColor) {
        cpuValueLabel.stringValue = String(format: "%.0f%%", total)
        cpuValueLabel.textColor = smoothedColor
        cpuSparklineView.strokeColor = smoothedColor
        cpuSparklineView.fillColor = smoothedColor.withAlphaComponent(0.18)
        cpuSparklineView.values = history

        if coreBarViews.count != cores.count {
            while coresStack.arrangedSubviews.count > 0 {
                let v = coresStack.arrangedSubviews.last!
                coresStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
            coreBarViews = (0..<cores.count).map { idx in
                let bar = MetricBarView(
                    title: String(format: "Core %02d", idx),
                    valueText: "0%",
                    fraction: 0,
                    color: .systemTeal,
                    height: 5.5
                )
                coresStack.addArrangedSubview(bar)
                bar.leadingAnchor.constraint(equalTo: coresStack.leadingAnchor).isActive = true
                bar.trailingAnchor.constraint(equalTo: coresStack.trailingAnchor).isActive = true
                return bar
            }
            coresToggleButton.title = coresExpanded ? "▴ Nascondi" : "▾ \(cores.count) Core"
        }

        for (idx, val) in cores.enumerated() {
            if idx < coreBarViews.count {
                coreBarViews[idx].update(
                    valueText: String(format: "%.0f%%", val),
                    fraction: val / 100.0,
                    color: val > 90 ? .systemRed : .systemTeal
                )
            }
        }
    }

    func updateGPU(devices: [GPUDeviceSample], history: [Double]) {
        let peak = devices.compactMap { $0.utilization }.max()
        gpuValueLabel.stringValue = peak.map { String(format: "%.0f%%", $0) } ?? "—"
        gpuValueLabel.textColor = peak == nil ? .secondaryLabelColor : .systemPurple
        gpuSparklineView.values = peak == nil ? [] : history

        guard let device = devices.first else {
            gpuInfoLabel.stringValue = "Statistiche GPU non disponibili"
            gpuInfoLabel.toolTip = "Il driver non espone PerformanceStatistics via IOKit."
            gpuMemoryLabel.isHidden = true
            gpuAllocatedLabel.isHidden = true
            gpuRendererBar.isHidden = true
            gpuTilerBar.isHidden = true
            gpuDevicesStack.isHidden = true
            return
        }

        gpuInfoLabel.toolTip = nil
        let totalCores = devices.compactMap { $0.coreCount }.reduce(0, +)
        let coreText = totalCores > 0 ? " · \(totalCores) core GPU" : ""
        gpuInfoLabel.stringValue = devices.count == 1
            ? "GPU integrata\(coreText)"
            : "\(devices.count) GPU rilevate\(coreText) · max"

        // When more GPUs are present the summary uses the busiest device;
        // utilization percentages must not be added together.
        let selected = devices.first(where: { $0.utilization == peak }) ?? device
        if let renderer = selected.renderer {
            gpuRendererBar.isHidden = false
            gpuRendererBar.update(valueText: String(format: "%.0f%%", renderer), fraction: renderer / 100)
        } else {
            gpuRendererBar.isHidden = true
        }
        if let tiler = selected.tiler {
            gpuTilerBar.isHidden = false
            gpuTilerBar.update(valueText: String(format: "%.0f%%", tiler), fraction: tiler / 100)
        } else {
            gpuTilerBar.isHidden = true
        }
        if let inUse = selected.memoryInUse {
            gpuMemoryLabel.isHidden = false
            gpuMemoryLabel.stringValue = "RAM GPU in uso: \(formatBytes(inUse))"
        } else {
            gpuMemoryLabel.isHidden = true
        }
        if let allocated = selected.memoryAllocated {
            gpuAllocatedLabel.isHidden = false
            gpuAllocatedLabel.stringValue = "RAM GPU allocata: \(formatBytes(allocated))"
        } else {
            gpuAllocatedLabel.isHidden = true
        }

        gpuDevicesStack.isHidden = devices.count <= 1
        if devices.count > 1 {
            if gpuDeviceBars.count != devices.count {
                for bar in gpuDeviceBars {
                    gpuDevicesStack.removeArrangedSubview(bar)
                    bar.removeFromSuperview()
                }
                gpuDeviceBars = devices.indices.map { index in
                    let bar = MetricBarView(title: "GPU \(index + 1)", valueText: "—",
                                            fraction: 0, color: .systemPurple, height: 5.5)
                    gpuDevicesStack.addArrangedSubview(bar)
                    bar.leadingAnchor.constraint(equalTo: gpuDevicesStack.leadingAnchor).isActive = true
                    bar.trailingAnchor.constraint(equalTo: gpuDevicesStack.trailingAnchor).isActive = true
                    return bar
                }
            }
            for (index, item) in devices.enumerated() {
                gpuDeviceBars[index].update(
                    valueText: item.utilization.map { String(format: "%.0f%%", $0) } ?? "—",
                    fraction: (item.utilization ?? 0) / 100
                )
            }
        }
    }

    func updateRAM(
        total: Double,
        used: Double,
        active: Double,
        wired: Double,
        compressed: Double,
        free: Double,
        swapUsed: Double?,
        swapTotal: Double?,
        swapInRate: Double,
        swapOutRate: Double,
        pressure: (name: String, color: NSColor, level: Int)?,
        history: [Double],
        pressureHistory: [Int],
        swapHistory: [Double],
        health: MemoryHealthAssessment
    ) {
        let totalGiB = total / gib
        let usedGiB = used / gib
        let usedPct = total == 0 ? 0 : 100.0 * (used / total)
        ramValueLabel.stringValue = String(format: "%.1f / %.1f GiB (%.0f%%)", usedGiB, totalGiB, usedPct)

        ramSparklineView.values = history

        // Memory Pressure (Esplicita gestione null/errore)
        if let pressure = pressure {
            switch pressure.level {
            case 4:
                pressureBadgeLabel.stringValue = "■ Critica"
                pressureBadgeLabel.textColor = .systemRed
                ramValueLabel.textColor = .systemRed
                ramSparklineView.strokeColor = .systemRed
            case 2:
                pressureBadgeLabel.stringValue = "▲ Attenzione"
                pressureBadgeLabel.textColor = .systemYellow
                ramValueLabel.textColor = .systemYellow
                ramSparklineView.strokeColor = .systemYellow
            case 1:
                pressureBadgeLabel.stringValue = "● Normale"
                pressureBadgeLabel.textColor = .systemGreen
                ramValueLabel.textColor = .systemGreen
                ramSparklineView.strokeColor = .systemGreen
            default:
                pressureBadgeLabel.stringValue = "Non disponibile"
                pressureBadgeLabel.textColor = .secondaryLabelColor
                ramValueLabel.textColor = .labelColor
                ramSparklineView.strokeColor = .systemGray
            }
        } else {
            pressureBadgeLabel.stringValue = "Non disponibile"
            pressureBadgeLabel.textColor = .secondaryLabelColor
            ramValueLabel.textColor = .labelColor
            ramSparklineView.strokeColor = .systemGreen
        }

        pressureHistoryView.levels = pressureHistory
        healthStatusLabel.stringValue = (health.severity == 2 ? "■ " : health.severity == 1 ? "▲ " : "● ") + health.status
        healthStatusLabel.textColor = health.severity == 2 ? .systemRed : (health.severity == 1 ? .systemOrange : .secondaryLabelColor)
        healthDetailLabel.stringValue = health.detail

        activeBar.update(valueText: formatBytes(active), fraction: total == 0 ? 0 : active / total)
        wiredBar.update(valueText: formatBytes(wired), fraction: total == 0 ? 0 : wired / total)
        compressedBar.update(valueText: formatBytes(compressed), fraction: total == 0 ? 0 : compressed / total)
        freeBar.update(valueText: formatBytes(free), fraction: total == 0 ? 0 : free / total)

        let totalSwapRate = swapInRate + swapOutRate

        if let sUsed = swapUsed {
            swapUsageValue.stringValue = formatBytes(sUsed)
            swapUsageValue.toolTip = swapTotal.map { "Swap allocata da macOS: \(formatBytes($0)). La quantità allocata può variare." }
        } else {
            swapUsageValue.stringValue = "Non disponibile"
            swapUsageValue.toolTip = nil
        }

        // Separate directions: swap-in reads pages from disk, swap-out writes them.
        swapActivityValue.stringValue = "↓ \(formatRate(swapInRate)) · ↑ \(formatRate(swapOutRate))"
        swapActivityValue.textColor = totalSwapRate > (mib * 5) ? .systemOrange : .secondaryLabelColor

        // Normalize to the visible 60s peak, not a magic fixed maximum.
        let actualPeak = swapHistory.max() ?? 0
        let scale = max(mib, actualPeak)
        swapSparklineView.values = swapHistory.map { min(100.0, max(0.0, 100.0 * $0 / scale)) }
        swapSparklineCaption.stringValue = "SWAP I/O · 60s · picco \(formatRate(actualPeak))"

        // Thermal State
        let thermal = thermalStatus()
        thermalLabel.stringValue = "Stato termico: \(thermal.text)"
        thermalLabel.textColor = thermal.color
    }

    func updateTopProcesses(samples: [ProcessSample], error: String?) {
        topProcesses.update(samples: samples, error: error)
    }
}

// MARK: - MenuMeter Engine

final class MenuMeter: NSObject, NSPopoverDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: MenuBarText.fixedWidth)
    private let popover = NSPopover()
    private let dashboard = DashboardViewController()

    private var lastTicks: [UInt32]?
    private var cpuHistory: [Double] = []
    private var ramHistory: [Double] = []
    private var gpuHistory: [Double] = []
    private var latestGPUDevices: [GPUDeviceSample] = []
    private var pressureHistory: [Int] = []
    private var swapHistory: [Double] = []
    private var latestHealth: MemoryHealthAssessment?
    private var recentCPUSamples: [Double] = []

    private var lastSwapIns: UInt64?
    private var lastSwapOuts: UInt64?
    private var lastSwapSampleTime: TimeInterval?

    private var latestCPUData: (total: Double, cores: [Double])?
    private var latestRAMStats: (total: Double, used: Double, active: Double, wired: Double, compressed: Double, free: Double, swapUsed: Double?, swapTotal: Double?, swapInRate: Double, swapOutRate: Double, pressure: (name: String, color: NSColor, level: Int)?)?

    private var topProcessSamples: [ProcessSample] = []
    private var topProcessesError: String?

    private var timer: Timer?
    private var lastCloseTime: TimeInterval = 0
    private var isFetchingProcesses = false
    private var lastProcessFetch: TimeInterval = -100

    override init() {
        super.init()

        if let button = status.button {
            button.attributedTitle = MenuBarText.styled(cpu: nil, gpu: nil, ram: nil, severity: 0)
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.contentViewController = dashboard
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        dashboard.onQuit = { [weak self] in
            self?.quitApp()
        }

        dashboard.onToggleCores = { [weak self] in
            guard let self = self, self.popover.isShown else { return }
            self.popover.contentSize = self.dashboard.view.fittingSize
        }

        dashboard.onCopyDiagnostics = { [weak self] in
            self?.copyDiagnosticsToClipboard()
        }

        update()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.update()
        }

        let timer = Timer(timeInterval: 2, target: self,
                          selector: #selector(update), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func popoverDidClose(_ notification: Notification) {
        lastCloseTime = ProcessInfo.processInfo.systemUptime
    }

    @objc private func togglePopover() {
        guard let button = status.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCloseTime < 0.25 {
            return
        }

        update()
        popover.contentSize = dashboard.view.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Previously the snapshot was delayed until the next 2s timer tick.
        // Start fetching immediately after the popover becomes visible.
        fetchTopProcesses()
    }

    // Mach CPU Load
    private func cpuSnapshot() -> (total: Double, cores: [Double])? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var count: natural_t = 0
        var info: processor_info_array_t?
        var length: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO,
                                  &count, &info, &length) == KERN_SUCCESS,
              let info = info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(length) * MemoryLayout<integer_t>.size))
        }

        let n = Int(count)
        let stride = Int(CPU_STATE_MAX)
        guard n > 0, Int(length) >= n * stride else { return nil }
        let ticks = (0..<(n * stride)).map { UInt32(bitPattern: info[$0]) }
        defer { lastTicks = ticks }
        guard let previous = lastTicks, previous.count == ticks.count else { return nil }

        var loads: [Double] = []
        var busySum: UInt64 = 0
        var totalSum: UInt64 = 0

        for core in 0..<n {
            let start = core * stride
            let deltas = (0..<stride).map { index -> UInt64 in
                UInt64(ticks[start + index] &- previous[start + index])
            }
            let total = deltas.reduce(0, +)
            let idle = deltas[Int(CPU_STATE_IDLE)]
            let busy = total - idle
            busySum += busy
            totalSum += total
            loads.append(total == 0 ? 0 : 100 * Double(busy) / Double(total))
        }
        let aggregate = totalSum == 0 ? 0 : 100 * Double(busySum) / Double(totalSum)
        return (aggregate, loads)
    }

    // VM Statistics & Swap
    private func ramSnapshot() -> (stats: vm_statistics64_data_t, swapUsed: Double?, swapTotal: Double?, total: Double)? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let total = Double(ProcessInfo.processInfo.physicalMemory)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapAvailable = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        return (
            stats: stats,
            swapUsed: swapAvailable ? Double(swap.xsu_used) : nil,
            swapTotal: swapAvailable ? Double(swap.xsu_total) : nil,
            total: total
        )
    }

    // P0: Memory Pressure robusto
    private func memoryPressureStatus() -> (name: String, color: NSColor, level: Int)? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return nil
        }
        switch level {
        case 1:
            return ("Normale", .systemGreen, 1)
        case 2:
            return ("Attenzione", .systemYellow, 2)
        case 4:
            return ("Critica", .systemRed, 4)
        default:
            return ("Livello \(level)", .systemGray, Int(level))
        }
    }

    // P0: Fetch Top Processes by distinct PID & app info (solo a popover aperto)
    private func fetchTopProcesses() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !isFetchingProcesses, now - lastProcessFetch >= 6 else { return }
        isFetchingProcesses = true
        lastProcessFetch = now

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ProcessSnapshotParser.arguments
            var env = ProcessInfo.processInfo.environment
            env["LC_ALL"] = "C"
            task.environment = env
            let pipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errorPipe

            var items: [ProcessSample] = []
            var errorMessage: String?

            do {
                try task.run()
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                if task.terminationStatus != 0 {
                    let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    errorMessage = stderr.isEmpty ? "Errore ps (codice \(task.terminationStatus))" : "Errore ps: \(stderr)"
                } else if let output = String(data: outputData, encoding: .utf8) {
                    items = ProcessSnapshotParser.parse(output)
                    if items.isEmpty {
                        errorMessage = "ps non ha restituito processi validi"
                    }
                } else {
                    errorMessage = "Output ps non leggibile (UTF-8)"
                }
            } catch {
                errorMessage = "Impossibile eseguire ps: \(error.localizedDescription)"
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isFetchingProcesses = false
                self.topProcessSamples = items
                self.topProcessesError = errorMessage
                self.dashboard.updateTopProcesses(samples: items, error: errorMessage)
            }
        }
    }

    private func copyDiagnosticsToClipboard() {
        let dateStr = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("MenuMeter — Snapshot (\(dateStr))")

        if let cpu = latestCPUData {
            let avg = cpuHistory.isEmpty ? cpu.total : (cpuHistory.reduce(0, +) / Double(cpuHistory.count))
            lines.append("CPU: \(String(format: "%.0f%%", cpu.total)) (\(cpu.cores.count) core logici) · Media 60s: \(String(format: "%.0f%%", avg))")
        }

        if latestGPUDevices.isEmpty {
            lines.append("GPU: statistiche non disponibili (IOKit PerformanceStatistics)")
        } else {
            for (index, device) in latestGPUDevices.enumerated() {
                let usage = device.utilization.map { String(format: "%.0f%%", $0) } ?? "Non disponibile"
                let cores = device.coreCount.map { "\($0) core" } ?? "core non disponibili"
                lines.append("GPU \(index + 1): \(usage) · \(cores)")
                if let renderer = device.renderer {
                    lines.append("  Renderer: \(String(format: "%.0f%%", renderer))")
                }
                if let tiler = device.tiler {
                    lines.append("  Tiler: \(String(format: "%.0f%%", tiler))")
                }
                if let inUse = device.memoryInUse {
                    lines.append("  RAM unificata GPU in uso: \(formatBytes(inUse))")
                }
                if let allocated = device.memoryAllocated {
                    lines.append("  RAM unificata GPU allocata: \(formatBytes(allocated))")
                }
            }
        }

        let thermal = thermalStatus()
        lines.append("Stato termico: \(thermal.text)")

        if let ram = latestRAMStats {
            let usedGiB = ram.used / gib
            let totalGiB = ram.total / gib
            let pct = ram.total == 0 ? 0 : 100 * ram.used / ram.total
            let pressName = ram.pressure?.name ?? "Non disponibile"
            lines.append("RAM: \(String(format: "%.1f / %.1f GiB (%.0f%%)", usedGiB, totalGiB, pct)) · Pressione: \(pressName)")
            lines.append("RAM dettaglio: Attiva \(formatBytes(ram.active)) · Cablata \(formatBytes(ram.wired)) · Compressa \(formatBytes(ram.compressed)) · Libera \(formatBytes(ram.free))")
            if let health = latestHealth {
                lines.append("Diagnosi (finestra 60s): \(health.status) · \(health.detail)")
            }

            let swapAmount = ram.swapUsed.map(formatBytes) ?? "Non disponibile"
            let swapAllocated = ram.swapTotal.map(formatBytes) ?? "Non disponibile"
            lines.append("Swap su disco: \(swapAmount) · Allocata dinamicamente: \(swapAllocated) (non è un limite massimo fisso)")
            lines.append("Swap I/O: in \(formatRate(ram.swapInRate)) · out \(formatRate(ram.swapOutRate)) · Picco 60s: \(formatRate(swapHistory.max() ?? 0))")
        }

        if let error = topProcessesError {
            lines.append("Raccolta processi: \(error)")
        }

        for (label, sortCPU) in [("Top CPU", true), ("Top RAM RSS", false)] {
            let top = ProcessRanker.make(topProcessSamples, groupApps: true, sortCPU: sortCPU).prefix(5)
            if !top.isEmpty {
                lines.append("\(label) (app raggruppate se identificabili):")
                for item in top {
                    lines.append("  • \(item.name) · CPU \(String(format: "%.1f%%", item.cpu)) · RSS \(formatBytes(item.rss)) · \(item.subtitle)")
                }
            }
        }

        let text = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func update() {
        let cpu = cpuSnapshot()
        let ramData = ramSnapshot()
        let gpuDevices = GPUReader.snapshot()
        latestGPUDevices = gpuDevices
        if let gpuUsage = gpuDevices.compactMap({ $0.utilization }).max() {
            gpuHistory.append(gpuUsage)
            if gpuHistory.count > 30 {
                gpuHistory.removeFirst(gpuHistory.count - 30)
            }
        }
        dashboard.updateGPU(devices: gpuDevices, history: gpuHistory)

        if let cpu = cpu {
            latestCPUData = cpu
            cpuHistory.append(cpu.total)
            if cpuHistory.count > 30 {
                cpuHistory.removeFirst(cpuHistory.count - 30)
            }

            recentCPUSamples.append(cpu.total)
            if recentCPUSamples.count > 3 {
                recentCPUSamples.removeFirst(recentCPUSamples.count - 3)
            }
            let avgRecent = recentCPUSamples.reduce(0, +) / Double(recentCPUSamples.count)
            let smoothedColor: NSColor = avgRecent > 88.0 ? .systemRed : (avgRecent > 70.0 ? .systemOrange : .systemBlue)

            dashboard.updateCPU(total: cpu.total, history: cpuHistory, cores: cpu.cores, smoothedColor: smoothedColor)
        }

        if let ramData = ramData {
            let stats = ramData.stats
            let page = Double(sysconf(_SC_PAGESIZE))
            let free = Double(stats.free_count) * page
            let inactive = Double(stats.inactive_count) * page
            let used = max(0, min(ramData.total, ramData.total - free - inactive))
            let active = Double(stats.active_count) * page
            let wired = Double(stats.wire_count) * page
            let compressed = Double(stats.compressor_page_count) * page

            let now = ProcessInfo.processInfo.systemUptime
            var swapInRate: Double = 0
            var swapOutRate: Double = 0
            if let prevIns = lastSwapIns, let prevOuts = lastSwapOuts, let prevTime = lastSwapSampleTime {
                let dt = max(now - prevTime, 0.5)
                let deltaIns = stats.swapins >= prevIns ? stats.swapins - prevIns : 0
                let deltaOuts = stats.swapouts >= prevOuts ? stats.swapouts - prevOuts : 0
                swapInRate = (Double(deltaIns) * page) / dt
                swapOutRate = (Double(deltaOuts) * page) / dt
            }
            lastSwapIns = stats.swapins
            lastSwapOuts = stats.swapouts
            lastSwapSampleTime = now

            let pressure = memoryPressureStatus()
            pressureHistory.append(pressure?.level ?? 0)
            swapHistory.append(swapInRate + swapOutRate)
            if pressureHistory.count > 30 { pressureHistory.removeFirst(pressureHistory.count - 30) }
            if swapHistory.count > 30 { swapHistory.removeFirst(swapHistory.count - 30) }
            let health = MemoryHealthAnalyzer.assess(pressureLevels: pressureHistory, swapRates: swapHistory)
            latestHealth = health

            let usedPct = ramData.total == 0 ? 0 : (used / ramData.total) * 100.0
            ramHistory.append(usedPct)
            if ramHistory.count > 30 {
                ramHistory.removeFirst(ramHistory.count - 30)
            }

            latestRAMStats = (
                total: ramData.total,
                used: used,
                active: active,
                wired: wired,
                compressed: compressed,
                free: free,
                swapUsed: ramData.swapUsed,
                swapTotal: ramData.swapTotal,
                swapInRate: swapInRate,
                swapOutRate: swapOutRate,
                pressure: pressure
            )

            dashboard.updateRAM(
                total: ramData.total,
                used: used,
                active: active,
                wired: wired,
                compressed: compressed,
                free: free,
                swapUsed: ramData.swapUsed,
                swapTotal: ramData.swapTotal,
                swapInRate: swapInRate,
                swapOutRate: swapOutRate,
                pressure: pressure,
                history: ramHistory,
                pressureHistory: pressureHistory,
                swapHistory: swapHistory,
                health: health
            )

        }

        let severity = latestHealth?.severity ?? 0
        status.button?.attributedTitle = MenuBarText.styled(cpu: latestCPUData?.total,
            gpu: gpuDevices.compactMap { $0.utilization }.max(),
            ram: latestRAMStats.map { $0.total > 0 ? 100 * $0.used / $0.total : 0 },
            severity: severity)

        if popover.isShown {
            fetchTopProcesses()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

#if MENUMETER_TEST
// Pure-logic smoke tests: no GUI, no permission prompts, no synthetic swap usage.
let statusCases = [
    MenuBarText.make(cpu: 8, gpu: 0, ram: 69, severity: 0),
    MenuBarText.make(cpu: 100, gpu: 100, ram: 100, severity: 2),
    MenuBarText.make(cpu: nil, gpu: nil, ram: nil, severity: 1),
    MenuBarText.make(cpu: 9, gpu: 10, ram: 99, severity: 0)
]
assert(Set(statusCases.map { $0.count }).count == 1, "menu bar must be stable at every utilization")
assert(statusCases[0].contains("CPU   8%"))
assert(statusCases[1].contains("GPU 100%"))
assert(statusCases[2].contains("GPU    —"))
// Check the actual attributed layout, not only the fallback plain text.
// Reserve enough width for the widest styled content plus AppKit insets.
let statusStyleCases = [
    MenuBarText.styled(cpu: 8, gpu: 0, ram: 69, severity: 0),
    MenuBarText.styled(cpu: 100, gpu: 100, ram: 100, severity: 2),
    MenuBarText.styled(cpu: nil, gpu: nil, ram: nil, severity: 1),
    MenuBarText.styled(cpu: 9, gpu: 10, ram: 99, severity: 0)
]
assert(statusStyleCases.allSatisfy { $0.size().width <= MenuBarText.fixedWidth - 16 },
       "colored labels must fit the reserved status-item width, including insets")
assert(MenuBarText.fixedWidth >= 234)
print("MenuMeter status width: \(MenuBarText.fixedWidth)pt · case text widths: \(statusStyleCases.map { Int(ceil($0.size().width)) })pt")
assert(statusStyleCases.allSatisfy { $0.string.contains("CPU") && $0.string.contains("GPU") && $0.string.contains("RAM") })
assert(Set(statusStyleCases.map { $0.string.count }).count == 1)
assert(ProcessIdentity.bundleRoot("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper") == "/Applications/Google Chrome.app")
assert(ProcessIdentity.bundleRoot("/opt/homebrew/bin/python3") == nil)
assert(ProcessIdentity.applicationName("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome") == "Google Chrome")
assert(ProcessIdentity.executableName("/opt/homebrew/bin/python3") == "python3")
let mockProcesses: [ProcessSample] = [
    ProcessSample(pid: 101, cpu: 10, rss: 800 * mib, comm: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    ProcessSample(pid: 102, cpu: 5, rss: 200 * mib, comm: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
    ProcessSample(pid: 103, cpu: 20, rss: 100 * mib, comm: "/opt/homebrew/bin/python3"),
    ProcessSample(pid: 104, cpu: 1, rss: 600 * mib, comm: "/opt/homebrew/bin/python3")
]
let grouped = ProcessRanker.make(mockProcesses, groupApps: true, sortCPU: true)
assert(grouped.count == 3, "only processes in the same app bundle should aggregate")
assert(grouped.first?.representativePID == 103)
let chrome = grouped.first(where: { $0.name == "Google Chrome" })
assert(chrome?.cpu == 15 && chrome?.rss == 1000 * mib && chrome?.members.count == 2)
let ungrouped = ProcessRanker.make(mockProcesses, groupApps: false, sortCPU: false)
assert(ungrouped.count == 4 && ungrouped.first?.representativePID == 101)

let gpu = GPUStatisticsParser.parse([
    "Device Utilization %": 76,
    "Renderer Utilization %": 58,
    "Tiler Utilization %": 20,
    "In use system memory": 1_073_741_824,
    "Alloc system memory": 2_147_483_648
])
assert(gpu.utilization == 76 && gpu.renderer == 58 && gpu.tiler == 20)
assert(gpu.memoryInUse == gib && gpu.memoryAllocated == 2 * gib)
assert(GPUStatisticsParser.parse(["GPU Activity(%)": "27.5%"]).utilization == 27.5)
assert(GPUStatisticsParser.parse(["Device Utilization %": -1]).utilization == nil)
assert(GPUStatisticsParser.parse(["Device Utilization %": 120]).utilization == nil)
assert(GPUStatisticsParser.parse(["GPU Activity(%)": "NaN"]).utilization == nil)
assert(GPUStatisticsParser.parse([:]).utilization == nil)

private let sample = ProcessSnapshotParser.parse("  123  3.5  1048576 /usr/local/bin/llama server\n\t456\t0.0\t5120\tGoogle Chrome Helper\n")
assert(sample.count == 2)
assert(sample[0].pid == 123 && sample[0].rss == 1_073_741_824)
assert(sample[0].comm == "/usr/local/bin/llama server")
assert(sample[1].pid == 456 && sample[1].comm == "Google Chrome Helper")
assert(ProcessSnapshotParser.parse("bogus input\n").isEmpty)
let psCheck = Process()
psCheck.executableURL = URL(fileURLWithPath: "/bin/ps")
psCheck.arguments = ProcessSnapshotParser.arguments
let psOutput = Pipe()
psCheck.standardOutput = psOutput
try psCheck.run()
let realProcesses = psOutput.fileHandleForReading.readDataToEndOfFile()
psCheck.waitUntilExit()
assert(psCheck.terminationStatus == 0)
assert(!ProcessSnapshotParser.parse(String(data: realProcesses, encoding: .utf8) ?? "").isEmpty,
       "macOS ps must return at least one parsed RSS process")
let normal = MemoryHealthAnalyzer.assess(pressureLevels: Array(repeating: 1, count: 30), swapRates: Array(repeating: 0, count: 30))
assert(normal.severity == 0 && normal.status == "Memoria stabile")
let briefYellow = MemoryHealthAnalyzer.assess(pressureLevels: [1, 1, 2, 2], swapRates: [0, 0, 0, 0])
assert(briefYellow.severity == 0)
let yellow = MemoryHealthAnalyzer.assess(pressureLevels: Array(repeating: 2, count: 15), swapRates: Array(repeating: 0, count: 15))
assert(yellow.severity == 1 && yellow.status.contains("persistente"))
let red = MemoryHealthAnalyzer.assess(pressureLevels: [4, 4, 4], swapRates: [0, 0, 0])
assert(red.severity == 2)
let thrash = MemoryHealthAnalyzer.assess(pressureLevels: Array(repeating: 1, count: 10), swapRates: Array(repeating: 6 * mib, count: 10))
assert(thrash.severity == 1 && thrash.status == "Swap I/O intensa")
let briefSwap = MemoryHealthAnalyzer.assess(pressureLevels: [1, 1], swapRates: [6 * mib, 0])
assert(briefSwap.severity == 0)
let unknown = MemoryHealthAnalyzer.assess(pressureLevels: [0], swapRates: [0])
assert(unknown.status == "Pressione non disponibile")
let unrecognized = MemoryHealthAnalyzer.assess(pressureLevels: [3], swapRates: [0])
assert(unrecognized.status == "Pressione non disponibile")
// Occupied-but-idle swap must not trigger an alert: only actual I/O and pressure count.
let recovered = MemoryHealthAnalyzer.assess(pressureLevels: [2, 2, 2, 1], swapRates: [6 * mib, 6 * mib, 6 * mib, 0])
assert(recovered.severity == 0)
// Instantiate the actual AppKit dashboard to catch view-hierarchy regressions.
_ = NSApplication.shared
let layoutProbe = DashboardViewController()
let layoutRoot = layoutProbe.view
assert(layoutRoot.fittingSize.width >= 540)
layoutProbe.updateTopProcesses(samples: mockProcesses, error: nil)
assert(layoutProbe.topProcesses.arrangedSubviews.count >= 4)
// Regression: short and long names must start at the same left edge, with the
// full available name-column width rather than their own intrinsic width.
let processTable = TopProcessesSectionView(frame: NSRect(x: 0, y: 0, width: 512, height: 460))
processTable.update(samples: mockProcesses, error: nil)
processTable.layoutSubtreeIfNeeded()
let processRows = processTable.arrangedSubviews
    .compactMap { $0 as? NSStackView }
    .flatMap { $0.arrangedSubviews.compactMap { $0 as? TopProcessRowView } }
assert(processRows.count == 3)
let nameRects: [NSRect] = processRows.compactMap { row in
    guard let header = row.arrangedSubviews.first as? NSStackView,
          header.arrangedSubviews.count > 1,
          let nameStack = header.arrangedSubviews[1] as? NSStackView else { return nil }
    return nameStack.convert(nameStack.bounds, to: processTable)
}
assert(nameRects.count == 3)
assert(nameRects.allSatisfy { abs($0.minX - nameRects[0].minX) < 1 })
assert(nameRects.allSatisfy { $0.width > 180 }, "name column must not collapse")
print("MenuMeter CPU/GPU/RAM and left-aligned process layout tests passed")
#else
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let monitor = MenuMeter()
app.run()
#endif
