import AppKit
import Darwin

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
        return String(format: "%.1f MB/s", bytesPerSec / mib)
    } else if bytesPerSec >= kib {
        return String(format: "%.0f KB/s", bytesPerSec / kib)
    } else {
        return "0 KB/s"
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

// MARK: - Top Process Row & Section (Cliccabile)

final class TopProcessRowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let trackView = ProgressTrackView(height: 3.5)
    private var currentPID: pid_t?

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        wantsLayer = true

        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.isBezeled = false
        valueLabel.drawsBackground = false
        valueLabel.isEditable = false
        valueLabel.isSelectable = false
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let labels = NSStackView(views: [nameLabel, valueLabel])
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

            trackView.topAnchor.constraint(equalTo: labels.bottomAnchor, constant: 2),
            trackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackView.heightAnchor.constraint(equalToConstant: 3.5),
            trackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(pid: pid_t, name: String, valueText: String, fraction: Double, color: NSColor, tooltipText: String) {
        self.currentPID = pid
        nameLabel.stringValue = name
        valueLabel.stringValue = valueText
        trackView.fraction = fraction
        trackView.fillColor = color
        self.toolTip = tooltipText
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let pid = currentPID else { return }
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
            app.activate()
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        }
    }
}

final class TopProcessesSectionView: NSStackView {
    private let headerLabel = NSTextField(labelWithString: "")
    private let rows: [TopProcessRowView] = [TopProcessRowView(), TopProcessRowView(), TopProcessRowView()]

    init(title: String) {
        super.init(frame: .zero)
        orientation = .vertical
        spacing = 5
        alignment = .leading

        headerLabel.stringValue = title
        headerLabel.font = .systemFont(ofSize: 10.5, weight: .bold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.isBezeled = false
        headerLabel.drawsBackground = false
        headerLabel.isEditable = false
        headerLabel.isSelectable = false
        addArrangedSubview(headerLabel)

        headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true

        for row in rows {
            addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(processes: [(pid: pid_t, name: String, valueText: String, fraction: Double, color: NSColor, tooltip: String)]) {
        for i in 0..<rows.count {
            if i < processes.count {
                rows[i].isHidden = false
                let p = processes[i]
                rows[i].update(pid: p.pid, name: p.name, valueText: p.valueText, fraction: p.fraction, color: p.color, tooltipText: p.tooltip)
            } else {
                rows[i].isHidden = true
            }
        }
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
    let cpuTopProcesses = TopProcessesSectionView(title: "TOP PROCESSI CPU")
    var coresExpanded: Bool = false

    // RAM Section
    let ramTitleLabel = NSTextField(labelWithString: "RAM")
    let ramValueLabel = NSTextField(labelWithString: "0 / 0 GiB")
    let ramSparklineView = SparklineView()
    let ramSparklineCaption = NSTextField(labelWithString: "Ultimi 60s")

    let pressureTitleLabel = NSTextField(labelWithString: "Pressione memoria")
    let pressureBadgeLabel = NSTextField(labelWithString: "● Normale")

    let activeBar = MetricBarView(title: "Attiva", valueText: "0 GiB", fraction: 0, color: .systemCyan)
    let wiredBar = MetricBarView(title: "Cablata", valueText: "0 GiB", fraction: 0, color: .systemIndigo)
    let compressedBar = MetricBarView(title: "Compressa", valueText: "0 GiB", fraction: 0, color: .systemPurple)
    let freeBar = MetricBarView(title: "Libera", valueText: "0 GiB", fraction: 0, color: .systemGray)
    let swapUsedBar = MetricBarView(title: "Swap occupata", valueText: "0 GiB", fraction: 0, color: .systemOrange)

    let swapActivityTitle = NSTextField(labelWithString: "Attività swap")
    let swapActivityValue = NSTextField(labelWithString: "Inattiva (0 KB/s)")

    let ramTopProcesses = TopProcessesSectionView(title: "TOP PROCESSI RAM (RSS)")

    // Footer
    let thermalLabel = NSTextField(labelWithString: "Stato termico: Nominale")
    let copyDiagButton = NSButton(title: "Copia diagnostica", target: nil, action: nil)

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

        let separator = NSBox()
        separator.boxType = .separator

        let footerStack = buildFooter()

        root.addSubview(columns)
        root.addSubview(separator)
        root.addSubview(footerStack)

        columns.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 540),

            columns.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            columns.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            columns.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            separator.topAnchor.constraint(equalTo: columns.bottomAnchor, constant: 10),
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

        // Top CPU Processes
        column.addArrangedSubview(cpuTopProcesses)
        cpuTopProcesses.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        cpuTopProcesses.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

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

        // RAM Bars: Attiva, Cablata, Compressa, Libera, Swap
        for bar in [activeBar, wiredBar, compressedBar, freeBar, swapUsedBar] {
            column.addArrangedSubview(bar)
            bar.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
            bar.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        }

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

        // Top RAM Processes
        column.addArrangedSubview(ramTopProcesses)
        ramTopProcesses.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        ramTopProcesses.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

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

        let line1 = NSStackView(views: [thermalLabel, copyDiagButton])
        line1.orientation = .horizontal
        line1.distribution = .fill

        // Line 2: Version, Auto-start, Quit
        let appTitle = NSTextField(labelWithString: "MenuMeter v3")
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
        history: [Double]
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
            default:
                pressureBadgeLabel.stringValue = "● Normale"
                pressureBadgeLabel.textColor = .systemGreen
                ramValueLabel.textColor = .systemGreen
                ramSparklineView.strokeColor = .systemGreen
            }
        } else {
            pressureBadgeLabel.stringValue = "Non disponibile"
            pressureBadgeLabel.textColor = .secondaryLabelColor
            ramValueLabel.textColor = .labelColor
            ramSparklineView.strokeColor = .systemGreen
        }

        activeBar.update(valueText: formatBytes(active), fraction: total == 0 ? 0 : active / total)
        wiredBar.update(valueText: formatBytes(wired), fraction: total == 0 ? 0 : wired / total)
        compressedBar.update(valueText: formatBytes(compressed), fraction: total == 0 ? 0 : compressed / total)
        freeBar.update(valueText: formatBytes(free), fraction: total == 0 ? 0 : free / total)

        let totalSwapRate = swapInRate + swapOutRate

        // Swap occupata: arancione/rosso SOLO se c'è attività attiva o soglia elevata sostenuta
        if let sUsed = swapUsed, let sTotal = swapTotal, sTotal > 0 {
            let frac = min(sUsed / sTotal, 1.0)
            let swapBarColor: NSColor
            if totalSwapRate > (mib * 5) {
                swapBarColor = .systemRed
            } else if totalSwapRate > (kib * 250) {
                swapBarColor = .systemOrange
            } else {
                swapBarColor = .systemGray
            }

            swapUsedBar.update(
                valueText: String(format: "%.1f / %.1f GiB", sUsed / gib, sTotal / gib),
                fraction: frac,
                color: swapBarColor
            )
        } else {
            swapUsedBar.update(valueText: "0.0 GiB", fraction: 0, color: .systemGray)
        }

        // Swap activity rate
        if totalSwapRate < kib {
            swapActivityValue.stringValue = "Inattiva (0 KB/s)"
            swapActivityValue.textColor = .secondaryLabelColor
        } else {
            swapActivityValue.stringValue = "Attiva: in \(formatRate(swapInRate)) · out \(formatRate(swapOutRate))"
            swapActivityValue.textColor = totalSwapRate > (mib * 5) ? .systemRed : .systemOrange
        }

        // Thermal State
        let thermal = thermalStatus()
        thermalLabel.stringValue = "Stato termico: \(thermal.text)"
        thermalLabel.textColor = thermal.color
    }

    func updateTopProcesses(
        cpu: [(pid: pid_t, name: String, valueText: String, fraction: Double, color: NSColor, tooltip: String)],
        ram: [(pid: pid_t, name: String, valueText: String, fraction: Double, color: NSColor, tooltip: String)]
    ) {
        cpuTopProcesses.update(processes: cpu)
        ramTopProcesses.update(processes: ram)
    }
}

// MARK: - MenuMeter Engine

final class MenuMeter: NSObject, NSPopoverDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let dashboard = DashboardViewController()

    private var lastTicks: [UInt32]?
    private var cpuHistory: [Double] = []
    private var ramHistory: [Double] = []
    private var recentCPUSamples: [Double] = []

    private var lastSwapIns: UInt64?
    private var lastSwapOuts: UInt64?
    private var lastSwapSampleTime: TimeInterval?

    private var latestCPUData: (total: Double, cores: [Double])?
    private var latestRAMStats: (total: Double, used: Double, active: Double, wired: Double, compressed: Double, free: Double, swapUsed: Double?, swapTotal: Double?, swapInRate: Double, swapOutRate: Double, pressure: (name: String, color: NSColor, level: Int)?)?

    private var topCPUList: [(pid: pid_t, name: String, valueText: String, fraction: Double, color: NSColor, tooltip: String)] = []
    private var topRAMList: [(pid: pid_t, name: String, valueText: String, fraction: Double, color: NSColor, tooltip: String)] = []

    private var timer: Timer?
    private var lastCloseTime: TimeInterval = 0
    private var isFetchingProcesses = false

    override init() {
        super.init()

        if let button = status.button {
            button.title = "CPU … · RAM …"
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
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
        guard !isFetchingProcesses else { return }
        isFetchingProcesses = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            task.launchPath = "/bin/ps"
            task.arguments = ["-A", "-c", "-o", "pid,%cpu,rss,comm", "-r"]
            let pipe = Pipe()
            task.standardOutput = pipe

            struct ProcItem {
                let pid: pid_t
                let cpu: Double
                let rss: Double
                let comm: String
            }

            var items: [ProcItem] = []

            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()

                if let output = String(data: data, encoding: .utf8) {
                    let lines = output.components(separatedBy: "\n")
                    for line in lines.dropFirst() {
                        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                        guard parts.count == 4,
                              let pid = pid_t(parts[0]),
                              let cpu = Double(parts[1]),
                              let rssKB = Double(parts[2]) else { continue }
                        items.append(ProcItem(pid: pid, cpu: cpu, rss: rssKB * 1024, comm: String(parts[3])))
                    }
                }
            } catch {
                // ignore
            }

            // Top CPU by distinct process
            let topCPU = items.sorted { $0.cpu > $1.cpu }.prefix(3).map { item -> (pid: pid_t, name: String, valueText: String, fraction: Double, color: NSColor, tooltip: String) in
                let app = NSRunningApplication(processIdentifier: item.pid)
                let name = cleanProcessName(app?.localizedName ?? item.comm)
                let pct = item.cpu
                let color: NSColor = pct > 150.0 ? .systemOrange : .systemBlue
                let frac = min(pct / 100.0, 1.0)
                let tooltip = "PID \(item.pid): \(item.comm)\nCPU: \(String(format: "%.1f%%", pct))\nRAM: \(formatBytes(item.rss)) (RSS stimata)\nFai clic per aprire Monitoraggio Attività o portare in primo piano."
                return (pid: item.pid, name: name, valueText: String(format: "%.0f%%", pct), fraction: frac, color: color, tooltip: tooltip)
            }

            // Top RAM by distinct process
            let totalRam = Double(ProcessInfo.processInfo.physicalMemory)
            let topRAM = items.sorted { $0.rss > $1.rss }.prefix(3).map { item -> (pid: pid_t, name: String, valueText: String, fraction: Double, color: NSColor, tooltip: String) in
                let app = NSRunningApplication(processIdentifier: item.pid)
                let name = cleanProcessName(app?.localizedName ?? item.comm)
                let fraction = totalRam == 0 ? 0 : min(item.rss / totalRam, 1.0)
                let tooltip = "PID \(item.pid): \(item.comm)\nRAM: \(formatBytes(item.rss)) (RSS stimata)\nCPU: \(String(format: "%.1f%%", item.cpu))\nFai clic per aprire Monitoraggio Attività o portare in primo piano."
                return (pid: item.pid, name: name, valueText: formatBytes(item.rss), fraction: fraction, color: .systemCyan, tooltip: tooltip)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isFetchingProcesses = false
                self.topCPUList = Array(topCPU)
                self.topRAMList = Array(topRAM)
                self.dashboard.updateTopProcesses(cpu: self.topCPUList, ram: self.topRAMList)
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

        let thermal = thermalStatus()
        lines.append("Stato termico: \(thermal.text)")

        if let ram = latestRAMStats {
            let usedGiB = ram.used / gib
            let totalGiB = ram.total / gib
            let pct = ram.total == 0 ? 0 : 100 * ram.used / ram.total
            let pressName = ram.pressure?.name ?? "Non disponibile"
            lines.append("RAM: \(String(format: "%.1f / %.1f GiB (%.0f%%)", usedGiB, totalGiB, pct)) · Pressione: \(pressName)")
            lines.append("RAM dettaglio: Attiva \(formatBytes(ram.active)) · Cablata \(formatBytes(ram.wired)) · Compressa \(formatBytes(ram.compressed)) · Libera \(formatBytes(ram.free))")

            let swapU = (ram.swapUsed ?? 0) / gib
            let swapT = (ram.swapTotal ?? 0) / gib
            let swapRateTotal = ram.swapInRate + ram.swapOutRate
            let swapRateText = swapRateTotal < kib ? "Inattiva (0 KB/s)" : "Attiva: in \(formatRate(ram.swapInRate)) · out \(formatRate(ram.swapOutRate))"
            lines.append("Swap: \(String(format: "%.1f / %.1f GiB", swapU, swapT)) · Attività: \(swapRateText)")
        }

        if !topCPUList.isEmpty {
            lines.append("Top CPU:")
            for p in topCPUList {
                lines.append("  • \(p.name) (PID \(p.pid)): \(p.valueText)")
            }
        }

        if !topRAMList.isEmpty {
            lines.append("Top RAM (RSS stimata):")
            for p in topRAMList {
                lines.append("  • \(p.name) (PID \(p.pid)): \(p.valueText)")
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
                history: ramHistory
            )

            let cpuText = cpu.map { String(format: "%.0f%%", $0.total) } ?? "…"
            status.button?.title = "CPU \(cpuText) · RAM \(String(format: "%.0f%%", usedPct))"
        }

        if popover.isShown {
            fetchTopProcesses()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let monitor = MenuMeter()
app.run()
