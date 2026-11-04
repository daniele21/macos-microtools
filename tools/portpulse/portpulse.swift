import Foundation

// PortPulse: an on-device, read-only TCP listener monitor with an explicit,
// user-confirmed SIGTERM action. No daemon, root helper, or network service.

struct PortListener: Hashable {
    let pid: Int32
    let command: String
    let uid: Int?
    let host: String
    let port: Int

    enum Scope: String { case local, network }

    var scope: Scope {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" || h == "0:0:0:0:0:0:0:1" ||
            h == "127.0.0.1" || h.hasPrefix("127.") { return .local }
        return .network
    }

    var identifier: String { "\(pid)|\(host)|\(port)" }
    var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

enum PortPulseCore {
    // lsof -F is field-oriented; relying on human column widths loses long
    // names, IPv6 endpoints and process names containing whitespace.
    static func parse(_ output: String) -> [PortListener] {
        var pid: Int32?
        var command = "Processo sconosciuto"
        var uid: Int?
        var found = Set<PortListener>()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value)
                command = "Processo sconosciuto"
                uid = nil
            case "c":
                command = value.isEmpty ? "Processo sconosciuto" : value
            case "u":
                uid = Int(value)
            case "n":
                guard let pid, let endpoint = parseEndpoint(value) else { continue }
                found.insert(PortListener(pid: pid, command: command, uid: uid,
                                          host: endpoint.host, port: endpoint.port))
            default:
                break
            }
        }
        return found.sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            return $0.host < $1.host
        }
    }

    static func parseEndpoint(_ raw: String) -> (host: String, port: Int)? {
        // For TCP listeners, lsof emits names such as *:3000,
        // 127.0.0.1:1235, [::1]:5432 and [::]:8080.
        guard let colon = raw.lastIndex(of: ":"),
              let port = Int(raw[raw.index(after: colon)...]),
              (1...65535).contains(port) else { return nil }
        var host = String(raw[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard !host.isEmpty, !host.contains("->"), !host.contains(" ") else { return nil }
        return (host, port)
    }

    static func canTerminate(_ listener: PortListener, currentUID: Int, ownPID: Int32) -> Bool {
        listener.pid > 1 && listener.pid != ownPID &&
        listener.uid == currentUID
    }
}


struct PortPulseSummary: Equatable {
    let total: Int
    let local: Int
    let network: Int

    init(_ listeners: [PortListener]) {
        let allPorts = Set(listeners.map(\.port))
        let networkPorts = Set(listeners.filter { $0.scope == .network }.map(\.port))
        total = allPorts.count
        network = networkPorts.count
        // A port listening on both loopback and the network is classified as
        // network, preventing summary totals from exceeding the unique count.
        local = allPorts.subtracting(networkPorts).count
    }
}

extension PortPulseCore {
    static func matches(_ listener: PortListener, filter: Int, search: String) -> Bool {
        let scopeMatches = filter == 0 ||
            (filter == 1 && listener.scope == .local) ||
            (filter == 2 && listener.scope == .network)
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return scopeMatches && (term.isEmpty ||
            String(listener.port).contains(term) ||
            String(listener.pid).contains(term) ||
            listener.command.lowercased().contains(term) ||
            listener.host.lowercased().contains(term))
    }
}


// Deliberately small process-origin contract. Only display facts we can
// substantiate; "Next.js" is recognized from the actual process command,
// while project names are derived from on-disk repository roots or user CWD.
struct PortOriginInfo {
    let service: String
    let projectName: String?
    let projectPath: String?
    let elapsed: String?
}

enum PortPulseOriginCore {
    static func serviceName(lsofName: String, psCommand: String?) -> String {
        let command = (psCommand ?? "").lowercased()
        if command.contains("next-server") ||
           command.contains("next dev") || command.contains("next start") { return "Next.js" }
        if command.contains("astro dev") || command.contains("/astro/") { return "Astro" }
        if command.contains("vite") && (command.contains(" dev") || command.contains("/vite/")) { return "Vite" }
        if command.contains("uvicorn") { return "Uvicorn" }
        if command.contains("flask run") { return "Flask" }
        return lsofName
    }

    // BSD ps(1) etime examples: 03:15, 10:31:34, 2-05:30:12.
    static func elapsedLabel(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count <= 2 else { return nil }
        let days: Int
        let clock: String
        if parts.count == 2 {
            guard let parsed = Int(parts[0]), parsed >= 0 else { return nil }
            days = parsed
            clock = parts[1]
        } else {
            days = 0
            clock = parts[0]
        }
        let numbers = clock.split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard numbers.count == 2 || numbers.count == 3,
              numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        let hours = numbers.count == 3 ? numbers[0] : 0
        let minutes = numbers.count == 3 ? numbers[1] : numbers[0]
        let seconds = numbers.last!
        guard minutes < 60, seconds < 60 else { return nil }
        if days > 0 { return "\(days)g \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    static func psFields(_ output: String?) -> (elapsed: String?, command: String?) {
        guard let line = output?.split(whereSeparator: \.isNewline).first else { return (nil, nil) }
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = fields.first else { return (nil, nil) }
        return (String(first), fields.count > 1 ? String(fields[1]) : nil)
    }

    static func cwdFromLsof(_ output: String?) -> String? {
        guard let output else { return nil }
        return output.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("n/") })
            .map { String($0.dropFirst()) }
    }

    static func projectLocation(
        cwd: String?, isRepository: (String) -> Bool
    ) -> (name: String, path: String)? {
        guard let cwd, cwd.hasPrefix("/"), cwd != "/" else { return nil }
        var url = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        while url.path != "/" {
            if isRepository(url.path) {
                return (url.lastPathComponent, url.path)
            }
            url.deleteLastPathComponent()
        }

        // If .git is absent (e.g. a copied worktree), show a project-like
        // folder only for a user's development directories. Never pretend
        // /System, /usr or /Applications is an application project.
        let chunks = cwd.split(separator: "/").map(String.init)
        guard chunks.count >= 4, chunks[0] == "Users",
              ["Projects", "Personal", "Developer", "Code"].contains(chunks[2])
        else { return nil }
        let name = chunks[3]
        return (name, "/" + chunks.prefix(4).joined(separator: "/"))
    }
}


// Group by an actual lsof process name, not by common port numbers.
// Interpreters such as node/python are purposely isolated by PID: different
// development projects must never be merged into a bulk-stop group.
struct PortGroup {
    let key: String
    let name: String
    let listeners: [PortListener]

    var ports: [Int] { Array(Set(listeners.map(\.port))).sorted() }
    var pids: [Int32] { Array(Set(listeners.map(\.pid))).sorted() }
    var isNetwork: Bool { listeners.contains { $0.scope == .network } }
}

enum PortPulseGrouping {
    private static let genericRuntimes: Set<String> = [
        "node", "nodejs", "python", "python3", "java", "ruby", "php", "bash",
        "sh", "zsh", "swift", "bun", "deno", "npm", "pnpm", "yarn", "perl"
    ]
    private static let protectedNames: Set<String> = [
        "controlcenter", "finder", "windowserver", "launchd", "kernel_task",
        "mdnsresponder", "sharingd", "rapportd", "loginwindow", "syslogd",
        "systemuiserver", "coreaudiod", "distnoted", "airportd"
    ]

    static func key(for listener: PortListener) -> String {
        let name = listener.command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Unknown or generic names are not enough evidence of one logical
        // service when multiple interpreter processes share that name.
        let normalized = name.isEmpty ? "unknown" : name
        if genericRuntimes.contains(normalized) || normalized == "unknown" ||
            normalized == "processo sconosciuto" {
            return normalized + "|pid:\(listener.pid)"
        }
        return normalized
    }

    static func groups(_ listeners: [PortListener]) -> [PortGroup] {
        let byKey = Dictionary(grouping: listeners, by: key(for:))
        return byKey.map { key, values in
            let sorted = values.sorted {
                if $0.port != $1.port { return $0.port < $1.port }
                if $0.pid != $1.pid { return $0.pid < $1.pid }
                return $0.host < $1.host
            }
            return PortGroup(key: key, name: sorted[0].command, listeners: sorted)
        }.sorted {
            if ($0.ports.first ?? 0) != ($1.ports.first ?? 0) {
                return ($0.ports.first ?? 0) < ($1.ports.first ?? 0)
            }
            return $0.key < $1.key
        }
    }

    static func canStop(_ group: PortGroup, currentUID: Int, ownPID: Int32) -> Bool {
        guard group.ports.count > 1,
              !protectedNames.contains(group.name.trimmingCharacters(in: .whitespaces).lowercased()),
              !group.listeners.isEmpty else { return false }
        return group.listeners.allSatisfy {
            key(for: $0) == group.key &&
            PortPulseCore.canTerminate($0, currentUID: currentUID, ownPID: ownPID)
        }
    }

    // Fail closed: if any selected endpoint disappeared, a new process joined
    // the filtered group, or ownership changed, do not signal ANY process.
    static func validateStop(
        _ selected: PortGroup, against refreshed: PortGroup?,
        currentUID: Int, ownPID: Int32
    ) -> Bool {
        guard canStop(selected, currentUID: currentUID, ownPID: ownPID),
              let refreshed, selected.key == refreshed.key,
              canStop(refreshed, currentUID: currentUID, ownPID: ownPID) else { return false }
        return Set(selected.listeners) == Set(refreshed.listeners)
    }
}

struct PortPulseDiff {
    private(set) var initialized = false
    private var previous = Set<String>()

    mutating func newNetworkListeners(_ listeners: [PortListener]) -> [PortListener] {
        let network = listeners.filter { $0.scope == .network }
        let ids = Set(network.map(\.identifier))
        let newItems = initialized ? network.filter { !previous.contains($0.identifier) } : []
        previous = ids
        initialized = true
        return newItems
    }
}

#if os(macOS)
import AppKit
import Darwin

enum PortScanner {
    enum ScanError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let details): return details }
        }
    }

    static func scan() throws -> [PortListener] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcun"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() }
        catch { throw ScanError.unavailable("Impossibile avviare lsof: \(error.localizedDescription)") }
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        let output = String(decoding: data, as: UTF8.self)
        if process.terminationStatus == 1 && output.isEmpty { return [] }
        guard process.terminationStatus == 0 else {
            throw ScanError.unavailable("lsof non riuscito (exit \(process.terminationStatus)): \(output.prefix(180))")
        }
        return PortPulseCore.parse(output)
    }
}


// Separate from PortScanner: no extra work is performed on the periodic polling
// path. All commands execute without a shell and only on explicit row expansion.
enum PortProcessInspector {
    private static func command(_ executable: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let watchdog = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        guard task.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func inspect(_ listener: PortListener) -> PortOriginInfo {
        let pid = String(listener.pid)
        let ps = PortPulseOriginCore.psFields(
            command("/bin/ps", ["-p", pid, "-o", "etime=", "-o", "command="])
        )
        let cwd = PortPulseOriginCore.cwdFromLsof(
            command("/usr/sbin/lsof", ["-nP", "-a", "-p", pid, "-d", "cwd", "-Fn"])
        )
        let location = PortPulseOriginCore.projectLocation(cwd: cwd) { path in
            FileManager.default.fileExists(atPath: path + "/.git")
        }
        return PortOriginInfo(
            service: PortPulseOriginCore.serviceName(lsofName: listener.command,
                                                       psCommand: ps.command),
            projectName: location?.name,
            projectPath: location?.path,
            elapsed: PortPulseOriginCore.elapsedLabel(ps.elapsed)
        )
    }
}

private final class PortPulseFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class PortPulseRootView: NSVisualEffectView {
    var appearanceDidChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceDidChange?()
    }
}

// Resolve semantic colors after the view joins its actual window appearance,
// rather than capturing light-mode CGColors while constructing the popover.
private final class PortPulseSurfaceView: NSView {
    let fillColor: NSColor
    let strokeColor: NSColor
    let cornerRadius: CGFloat

    init(fill: NSColor, stroke: NSColor, radius: CGFloat) {
        fillColor = fill
        strokeColor = stroke
        cornerRadius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fillColor.cgColor
            layer?.borderColor = strokeColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// Design system for the compact menu-bar surface. Colors follow the macOS
// appearance; orange denotes non-loopback binds, not public Internet access.
private enum PortPulsePalette {
    static let inset: CGFloat = 14
    static let green = NSColor.systemGreen
    static let orange = NSColor.systemOrange
    static let neutral = NSColor.secondaryLabelColor
}

final class PortPulseViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onStop: ((PortListener) -> Void)?
    var onStopGroup: ((PortGroup, Int, String) -> Void)?
    var onInspect: ((PortListener) -> Void)?

    private let titleField = NSTextField(labelWithString: "PortPulse")
    private let updatedField = NSTextField(labelWithString: "In attesa della prima scansione")
    private let totalMetric = NSTextField(labelWithString: "—")
    private let localMetric = NSTextField(labelWithString: "—")
    private let networkMetric = NSTextField(labelWithString: "—")
    private let eventField = NSTextField(wrappingLabelWithString: "")
    private let filter = NSSegmentedControl(labels: ["Tutte", "Locali", "Rete"],
                                            trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let groupToggle = NSButton(checkboxWithTitle: "Raggruppa per servizio", target: nil, action: nil)
    private let rows = NSStackView()
    private let scroll = NSScrollView()
    private let footerField = NSTextField(labelWithString: "TCP · ogni 5 s")
    private var listeners: [PortListener] = []
    private var selectedID: String?
    private var expandedGroupKey: String?
    private var detailsByID: [String: (info: PortOriginInfo, fetchedAt: Date)] = [:]
    private var inspectingID: String?
    private var lastError: String?
    private var latestEvent: PortListener?
    private var hasLoaded = false

    override func loadView() {
        let root = PortPulseRootView(frame: NSRect(x: 0, y: 0, width: 426, height: 590))
        root.appearanceDidChange = { [weak self] in
            guard let self, self.hasLoaded else { return }
            self.rebuild()
        }
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        view = root

        titleField.font = .boldSystemFont(ofSize: 16)
        titleField.setAccessibilityLabel("PortPulse")
        updatedField.font = .systemFont(ofSize: 10)
        updatedField.textColor = .secondaryLabelColor
        updatedField.alignment = .right
        updatedField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Rete")
        symbol.contentTintColor = .controlAccentColor
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 21),
            symbol.heightAnchor.constraint(equalToConstant: 21)
        ])
        let head = horizontal([symbol, titleField, NSView(), updatedField], spacing: 7)

        let metricRow = horizontal([
            makeMetric("Totali", icon: "square.stack.3d.up", count: totalMetric, tint: .secondaryLabelColor),
            makeMetric("Locali", icon: "desktopcomputer", count: localMetric, tint: PortPulsePalette.green),
            makeMetric("Rete", icon: "network", count: networkMetric, tint: PortPulsePalette.orange)
        ], spacing: 8)
        metricRow.distribution = .fillEqually
        metricRow.heightAnchor.constraint(equalToConstant: 63).isActive = true

        filter.selectedSegment = 0
        filter.segmentStyle = .rounded
        filter.controlSize = .regular
        filter.target = self
        filter.action = #selector(filtersChanged)
        filter.toolTip = "Rete: binding non-loopback, non necessariamente accessibili da Internet"
        filter.heightAnchor.constraint(equalToConstant: 27).isActive = true
        // NSSegmentedControl otherwise keeps its natural ~135pt width.
        for index in 0..<3 { filter.setWidth(398.0 / 3.0, forSegment: index) }
        filter.widthAnchor.constraint(equalToConstant: 398).isActive = true

        search.placeholderString = "Cerca porta, processo, PID"
        search.controlSize = .regular
        search.focusRingType = .default
        search.target = self
        search.action = #selector(filtersChanged)
        search.sendsSearchStringImmediately = true
        search.heightAnchor.constraint(equalToConstant: 28).isActive = true

        groupToggle.state = .on
        groupToggle.controlSize = .small
        groupToggle.font = .systemFont(ofSize: 11)
        groupToggle.target = self
        groupToggle.action = #selector(groupModeChanged)
        groupToggle.toolTip = "Unisce le porte dello stesso servizio. Node e Python restano separati per processo."
        groupToggle.setAccessibilityLabel("Raggruppa porte dello stesso servizio")

        eventField.font = .systemFont(ofSize: 11, weight: .medium)
        eventField.textColor = .systemOrange
        eventField.maximumNumberOfLines = 2
        eventField.isHidden = true
        eventField.setAccessibilityLabel("Nuova porta non locale")

        rows.orientation = .vertical
        rows.spacing = 6
        rows.alignment = .width
        rows.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = PortPulseFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            // NSScrollView manages its document frame and may disregard a
            // clip-view-relative intrinsic width in an unconstrained stack.
            // This menu popover has a fixed 426pt width and 14pt side margins.
            // Pin document and rows to the exact content width to prevent
            // narrow right-aligned listener cards.
            document.widthAnchor.constraint(equalToConstant: 398),
            rows.widthAnchor.constraint(equalToConstant: 398),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])

        let refresh = NSButton(title: "", target: self, action: #selector(refreshClicked))
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Aggiorna")
        refresh.imagePosition = .imageOnly
        refresh.bezelStyle = .rounded
        refresh.toolTip = "Aggiorna le porte ora"
        refresh.setAccessibilityLabel("Aggiorna")
        refresh.widthAnchor.constraint(equalToConstant: 29).isActive = true

        let quit = NSButton(title: "Esci", target: self, action: #selector(quitClicked))
        quit.bezelStyle = .rounded
        quit.font = .systemFont(ofSize: 11)
        footerField.font = .systemFont(ofSize: 10)
        footerField.textColor = .tertiaryLabelColor
        footerField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = horizontal([footerField, NSView(), refresh, quit], spacing: 7)

        let separator = NSBox()
        separator.boxType = .separator
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let content = NSStackView(views: [head, metricRow, filter, search,
                                          groupToggle, eventField, scroll, separator, footer])
        content.orientation = .vertical
        content.spacing = 10
        content.alignment = .width
        content.distribution = .fill
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: PortPulsePalette.inset),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -PortPulsePalette.inset),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 15),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        hasLoaded = true
        rebuild(resetScroll: true)
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func vertical(_ views: [NSView], spacing: CGFloat = 3) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func label(_ value: String, size: CGFloat = 11,
                       weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let item = NSTextField(labelWithString: value)
        item.font = .systemFont(ofSize: size, weight: weight)
        item.textColor = color
        item.lineBreakMode = .byTruncatingTail
        item.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return item
    }

    private func surface(fill: NSColor, stroke: NSColor = .clear,
                         radius: CGFloat = 10) -> NSView {
        PortPulseSurfaceView(fill: fill, stroke: stroke, radius: radius)
    }

    private func makeMetric(_ caption: String, icon: String,
                            count: NSTextField, tint: NSColor) -> NSView {
        let bg = surface(fill: tint.withAlphaComponent(0.08),
                         stroke: tint.withAlphaComponent(0.23), radius: 11)
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: caption)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        iconView.contentTintColor = tint
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 18).isActive = true
        count.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        count.textColor = .labelColor
        let text = vertical([count, label(caption, size: 10, color: .secondaryLabelColor)], spacing: 0)
        let inside = horizontal([iconView, text], spacing: 8)
        inside.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(inside)
        NSLayoutConstraint.activate([
            inside.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 11),
            inside.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -8),
            inside.centerYAnchor.constraint(equalTo: bg.centerYAnchor)
        ])
        bg.setAccessibilityElement(true)
        bg.setAccessibilityRole(.group)
        bg.setAccessibilityLabel("Porte \(caption)")
        return bg
    }

    private func makeBadge(_ title: String, tint: NSColor) -> NSView {
        let bg = surface(fill: tint.withAlphaComponent(0.13),
                         stroke: tint.withAlphaComponent(0.3), radius: 8)
        let text = label(title, size: 10, weight: .medium, color: tint)
        text.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 7),
            text.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -7),
            text.topAnchor.constraint(equalTo: bg.topAnchor, constant: 4),
            text.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -4)
        ])
        bg.toolTip = title == "Rete"
            ? "Binding non-loopback: raggiungibilità effettiva dipendente da firewall e rete"
            : "Solo loopback, locale al Mac"
        return bg
    }

    func render(_ items: [PortListener], newExposures: [PortListener], error: String?) {
        let changed = items != listeners || lastError != error
        listeners = items
        // Cache is strictly in-memory and scoped to currently active listener
        // identities. Never keep a vanished PID's project origin around.
        let alive = Set(items.map(\.identifier))
        detailsByID = detailsByID.filter { alive.contains($0.key) }
        if let selectedID, !alive.contains(selectedID) {
            self.selectedID = nil
            inspectingID = nil
        }
        if let expandedGroupKey,
           !PortPulseGrouping.groups(items).contains(where: { $0.key == expandedGroupKey && $0.ports.count > 1 }) {
            self.expandedGroupKey = nil
        }
        lastError = error
        let oldEvent = latestEvent
        if let first = newExposures.first { latestEvent = first }
        if let existing = latestEvent, !items.contains(existing) { latestEvent = nil }

        // A successful poll updates the timestamp without rebuilding every card.
        // This preserves focus, selection and the current scroll position.
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        updatedField.stringValue = error == nil
            ? "● Aggiornato \(formatter.string(from: Date()))"
            : "⚠ Scansione non riuscita"
        updatedField.textColor = error == nil ? .secondaryLabelColor : .systemOrange
        if changed || oldEvent != latestEvent { rebuild() }
    }

    private var visible: [PortListener] {
        listeners.filter {
            PortPulseCore.matches($0, filter: filter.selectedSegment, search: search.stringValue)
        }
    }

    private var visibleGroups: [PortGroup] { PortPulseGrouping.groups(visible) }
    private var grouped: Bool { groupToggle.state == .on }

    private func rebuild(resetScroll: Bool = false) {
        guard hasLoaded else { return }
        let oldY = scroll.contentView.bounds.origin.y
        let summary = PortPulseSummary(listeners)
        totalMetric.stringValue = "\(summary.total)"
        localMetric.stringValue = "\(summary.local)"
        networkMetric.stringValue = "\(summary.network)"
        totalMetric.setAccessibilityLabel("\(summary.total) porte totali")
        localMetric.setAccessibilityLabel("\(summary.local) porte solo locali")
        networkMetric.setAccessibilityLabel("\(summary.network) porte con binding non-locali")

        if let error = lastError {
            footerField.stringValue = "Errore: \(error.prefix(55))"
            footerField.textColor = .systemOrange
        } else {
            footerField.stringValue = "TCP · aggiornamento ogni 5 s"
            footerField.textColor = .tertiaryLabelColor
        }
        if let event = latestEvent {
            eventField.stringValue = "▲ Nuova porta di rete · \(event.port) · \(event.command)"
            eventField.isHidden = false
        } else {
            eventField.isHidden = true
        }

        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let filtered = visible
        if filtered.isEmpty {
            let empty = label(lastError == nil ? "Nessuna porta corrispondente." : "Dati non disponibili.",
                              size: 12, color: .secondaryLabelColor)
            empty.alignment = .center
            let container = surface(fill: .controlBackgroundColor.withAlphaComponent(0.20))
            container.addSubview(empty)
            empty.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                empty.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                empty.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                container.heightAnchor.constraint(equalToConstant: 66)
            ])
            rows.addArrangedSubview(container)
            container.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        if grouped {
            for (index, group) in visibleGroups.enumerated() {
                if group.ports.count > 1 {
                    let card = makeGroupCard(group, index: index)
                    rows.addArrangedSubview(card)
                    card.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                } else {
                    // Singletons retain their existing one-port inspection UX.
                    for listener in group.listeners {
                        guard let itemIndex = filtered.firstIndex(of: listener) else { continue }
                        let card = makeListenerCard(listener, index: itemIndex)
                        rows.addArrangedSubview(card)
                        card.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                    }
                }
            }
        } else {
            for (index, item) in filtered.enumerated() {
                let card = makeListenerCard(item, index: index)
                rows.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }
        view.layoutSubtreeIfNeeded()
        if let document = scroll.documentView {
            let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: resetScroll ? 0 : min(oldY, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }


    private func makeGroupCard(_ group: PortGroup, index: Int) -> NSView {
        let expanded = group.key == expandedGroupKey
        let tint: NSColor = group.isNetwork ? PortPulsePalette.orange : PortPulsePalette.green
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg = NSColor(calibratedWhite: dark ? (expanded ? 0.22 : 0.19) :
                                             (expanded ? 0.97 : 0.95), alpha: 0.97)
        let card = surface(fill: bg,
                           stroke: expanded ? tint.withAlphaComponent(0.6) :
                                              .separatorColor.withAlphaComponent(0.14), radius: 11)

        let dot = surface(fill: tint, radius: 4)
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let name = label(group.name, size: 13, weight: .semibold)
        let countLabel = label("\(group.ports.count) porte · \(group.pids.count) processi",
                               size: 10, color: .secondaryLabelColor)
        let stack = vertical([name, countLabel], spacing: 2)
        let badge = makeBadge(group.isNetwork ? "Rete" : "Locale", tint: tint)
        let arrow = NSImageView()
        arrow.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down",
                              accessibilityDescription: "Dettagli gruppo")
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.widthAnchor.constraint(equalToConstant: 10).isActive = true

        let header = horizontal([dot, stack, NSView(), badge, arrow], spacing: 8)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 46).isActive = true
        let hit = NSButton(title: "", target: self, action: #selector(groupClicked(_:)))
        hit.tag = index
        hit.isBordered = false
        hit.isTransparent = true
        hit.setAccessibilityLabel("\(group.name), \(group.ports.count) porte, \(group.pids.count) processi. \(expanded ? "Chiudi" : "Apri") gruppo")
        header.addSubview(hit)
        hit.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hit.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hit.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            hit.topAnchor.constraint(equalTo: header.topAnchor),
            hit.bottomAnchor.constraint(equalTo: header.bottomAnchor)
        ])

        var sections: [NSView] = [header]
        if expanded {
            // One line per distinct port+PID: don't repeat dual-stack endpoints.
            var seen = Set<String>()
            let entries = group.listeners.filter { seen.insert("\($0.port)|\($0.pid)").inserted }
            let children = NSStackView()
            children.orientation = .vertical
            children.alignment = .width
            children.spacing = 4
            for entry in entries {
                let number = label(String(entry.port), size: 12, weight: .semibold)
                number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                number.widthAnchor.constraint(equalToConstant: 45).isActive = true
                let metadata = label("\(entry.host) · PID \(entry.pid)", size: 10,
                                     color: .secondaryLabelColor)
                let line = horizontal([number, metadata, NSView()], spacing: 6)
                line.heightAnchor.constraint(equalToConstant: 23).isActive = true
                children.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: children.widthAnchor).isActive = true
            }
            sections.append(children)

            let stop = smallButton("Termina gruppo…", symbol: "stop.circle",
                                   action: #selector(stopGroupClicked))
            stop.contentTintColor = .systemRed
            stop.isEnabled = PortPulseGrouping.canStop(group, currentUID: Int(getuid()),
                                                       ownPID: getpid())
            stop.toolTip = stop.isEnabled
                ? "Arresta tutti i \(group.pids.count) processi dopo conferma"
                : "Non consentito: processi di sistema, permessi insufficienti o gruppo non verificabile"
            let actionRow = horizontal([stop, NSView()], spacing: 6)
            sections.append(actionRow)
        }
        let body = vertical(sections, spacing: expanded ? 8 : 0)
        body.alignment = .width
        body.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        if expanded {
            // The list and footer stretch to content width; the button
            // itself stays compact in a flexible action row.
            sections[1].widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            sections[2].widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 11),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -11),
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: expanded ? 8 : 3),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: expanded ? -11 : -3)
        ])
        return card
    }

    private func makeListenerCard(_ item: PortListener, index: Int) -> NSView {
        let selected = item.identifier == selectedID
        let tint: NSColor = item.scope == .local ? PortPulsePalette.green : PortPulsePalette.orange
        // Explicit contrast tokens: semantic NSColor.windowBackgroundColor can
        // resolve as a light Aqua CGColor during offscreen AppKit layout.
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let cardFill = NSColor(calibratedWhite: dark ? (selected ? 0.22 : 0.19) :
                                                  (selected ? 0.97 : 0.95), alpha: 0.97)
        let card = surface(
            fill: cardFill,
            stroke: selected ? tint.withAlphaComponent(0.62) : .separatorColor.withAlphaComponent(0.14),
            radius: 11
        )
        let dot = surface(fill: tint, radius: 4)
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let port = label("\(item.port)", size: 14, weight: .semibold)
        port.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        port.widthAnchor.constraint(equalToConstant: 49).isActive = true
        let line = surface(fill: .separatorColor.withAlphaComponent(0.5), radius: 0)
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 25).isActive = true
        let info = detailsByID[item.identifier]?.info
        let process = label(info?.service ?? item.command, size: 12, weight: .semibold)
        let subline = info?.projectName ?? "\(item.host) · PID \(item.pid)"
        let metadata = label(subline, size: 10, color: .secondaryLabelColor)
        metadata.toolTip = info?.projectPath ?? item.address
        let textColumn = vertical([process, metadata], spacing: 2)
        textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let badge = makeBadge(item.scope == .local ? "Locale" : "Rete", tint: tint)
        let arrow = NSImageView()
        arrow.image = NSImage(systemSymbolName: selected ? "chevron.up" : "chevron.down",
                              accessibilityDescription: "Dettagli")
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.widthAnchor.constraint(equalToConstant: 10).isActive = true
        let header = horizontal([dot, port, line, textColumn, NSView(), badge, arrow], spacing: 7)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 45).isActive = true

        // A borderless accessible button overlays the visible header, making
        // the entire row clickable without compromising typographic layout.
        let hit = NSButton(title: "", target: self, action: #selector(rowClicked(_:)))
        hit.tag = index
        hit.isBordered = false
        hit.isTransparent = true
        hit.toolTip = "\(item.command) · \(item.address) · PID \(item.pid)"
        hit.setAccessibilityLabel("Porta \(item.port), \(info?.service ?? item.command), \(item.scope == .local ? "locale" : "rete"), \(selected ? "chiudi" : "apri") dettagli")
        header.addSubview(hit)
        hit.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hit.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hit.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            hit.topAnchor.constraint(equalTo: header.topAnchor),
            hit.bottomAnchor.constraint(equalTo: header.bottomAnchor)
        ])

        var elements: [NSView] = [header]
        if selected {
            let detailText: String
            if let info {
                let elapsed = info.elapsed.map { "Attivo da \($0)" }
                detailText = (["PID \(item.pid)", elapsed, item.host] as [String?])
                    .compactMap { $0 }.joined(separator: " · ")
            } else if inspectingID == item.identifier {
                detailText = "Identificazione in corso…"
            } else {
                detailText = "PID \(item.pid) · \(item.host)"
            }

            let detailLine = label(detailText, size: 11, color: .secondaryLabelColor)
            detailLine.toolTip = item.address
            elements.append(detailLine)

            var actions: [NSView] = []
            if let path = info?.projectPath {
                let openProject = smallButton("Apri progetto", symbol: "folder",
                                               action: #selector(projectClicked))
                openProject.toolTip = path
                actions.append(openProject)
            }
            let stop = smallButton("Termina…", symbol: "stop.circle",
                                   action: #selector(stopClicked))
            stop.contentTintColor = .systemRed
            stop.isEnabled = PortPulseCore.canTerminate(item, currentUID: Int(getuid()), ownPID: getpid())
            stop.toolTip = stop.isEnabled ? "Invia SIGTERM dopo conferma" : "Solo processi verificati del tuo utente"
            actions.append(stop)
            let actionRow = horizontal(actions, spacing: 7)
            elements.append(actionRow)
        }

        let inside = vertical(elements, spacing: selected ? 9 : 0)
        inside.alignment = .width
        inside.translatesAutoresizingMaskIntoConstraints = false
        // Vertical NSStackView's alignment does not guarantee that its
        // arranged children stretch to its own constrained width.
        // Pin each row section explicitly to prevent right-justified text.
        header.widthAnchor.constraint(equalTo: inside.widthAnchor).isActive = true
        if selected {
            for section in elements.dropFirst() {
                section.widthAnchor.constraint(equalTo: inside.widthAnchor).isActive = true
            }
        }
        card.addSubview(inside)
        NSLayoutConstraint.activate([
            inside.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            inside.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            inside.topAnchor.constraint(equalTo: card.topAnchor, constant: selected ? 9 : 3),
            inside.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: selected ? -11 : -3)
        ])
        return card
    }

    private func smallButton(_ text: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: text, target: self, action: action)
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.contentTintColor = .labelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.layer?.backgroundColor = NSColor(
            calibratedWhite: dark ? 0.32 : 0.87, alpha: 0.94
        ).cgColor
        button.heightAnchor.constraint(equalToConstant: 27).isActive = true
        return button
    }

    // Synthetic data is injected only in CLI snapshot mode; no real system
    // process is inspected when producing design screenshots.
    func preview(_ items: [PortListener], expanded item: PortListener) {
        if let group = PortPulseGrouping.groups(items).first(where: {
            $0.name == "llama-server" && $0.ports.count > 1
        }) {
            groupToggle.state = .on
            expandedGroupKey = group.key
            search.stringValue = "llama"
        } else {
            selectedID = item.identifier
            detailsByID[item.identifier] = (
                info: PortOriginInfo(service: "Next.js",
                                     projectName: "sdg-chat-activity-diagnostic-live",
                                     projectPath: "/Users/example/Projects/sdg-chat-activity-diagnostic-live",
                                     elapsed: "10h 31m"),
                fetchedAt: Date()
            )
        }
        render(items, newExposures: [], error: nil)
    }

    func inspected(_ info: PortOriginInfo, for listener: PortListener) {
        // Ignore results from old / closed rows or processes that disappeared.
        guard listeners.contains(listener), selectedID == listener.identifier else { return }
        detailsByID[listener.identifier] = (info: info, fetchedAt: Date())
        inspectingID = nil
        rebuild()
    }


    @objc private func groupModeChanged() {
        selectedID = nil
        expandedGroupKey = nil
        rebuild(resetScroll: true)
    }

    @objc private func groupClicked(_ sender: NSButton) {
        let groups = visibleGroups
        guard groups.indices.contains(sender.tag),
              groups[sender.tag].ports.count > 1 else { return }
        let key = groups[sender.tag].key
        selectedID = nil
        expandedGroupKey = expandedGroupKey == key ? nil : key
        rebuild()
    }

    @objc private func stopGroupClicked() {
        guard grouped,
              let expandedGroupKey,
              let group = visibleGroups.first(where: { $0.key == expandedGroupKey }),
              PortPulseGrouping.canStop(group, currentUID: Int(getuid()),
                                        ownPID: getpid()) else { return }
        let ports = group.ports.map(String.init).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Terminare \(group.pids.count) processi \(group.name)?"
        alert.informativeText =
            "Porte selezionate: \(ports)\n" +
            "Invierà SIGTERM ai \(group.pids.count) PID distinti. " +
            "Può interrompere lavori in corso e altre porte degli stessi processi. " +
            "Tutti i listener saranno ricontrollati prima dell'arresto. Nessun SIGKILL."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Annulla")
        alert.addButton(withTitle: "Termina \(group.pids.count) processi")
        if alert.runModal() == .alertSecondButtonReturn {
            onStopGroup?(group, filter.selectedSegment, search.stringValue)
        }
    }

    @objc private func filtersChanged() { rebuild(resetScroll: true) }

    @objc private func rowClicked(_ sender: NSButton) {
        let filtered = visible
        guard filtered.indices.contains(sender.tag) else { return }
        let item = filtered[sender.tag]
        let id = item.identifier
        selectedID = selectedID == id ? nil : id
        if selectedID == id {
            if let cached = detailsByID[id],
               Date().timeIntervalSince(cached.fetchedAt) < 60 {
                inspectingID = nil
            } else {
                inspectingID = id
                onInspect?(item)
            }
        }
        rebuild()
    }

    private var selected: PortListener? {
        listeners.first { $0.identifier == selectedID }
    }

    @objc private func projectClicked() {
        guard let item = selected, let path = detailsByID[item.identifier]?.info.projectPath else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: path) else {
            footerField.stringValue = "Cartella non più disponibile"
            return
        }
        let opened = NSWorkspace.shared.open(url)
        if !opened { footerField.stringValue = "Impossibile aprire il progetto" }
    }

    @objc private func stopClicked() {
        guard let item = selected,
              PortPulseCore.canTerminate(item, currentUID: Int(getuid()), ownPID: getpid()) else { return }
        let alert = NSAlert()
        alert.messageText = "Arrestare \(item.command)?"
        alert.informativeText = "PID \(item.pid) · \(item.address)\nIl processo riceverà SIGTERM. Potrebbe interrompere lavori in corso. Nessun SIGKILL automatico."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Invia SIGTERM")
        alert.addButton(withTitle: "Annulla")
        if alert.runModal() == .alertFirstButtonReturn { onStop?(item) }
    }

    func showActionResult(_ message: String) { footerField.stringValue = message }
    @objc private func refreshClicked() { onRefresh?() }
    @objc private func quitClicked() { onQuit?() }
}

// Keep the ordinary status item symbol as a macOS template so the system
// handles light/dark menu bar contrast. For a warning/error use a real,
// non-template, pre-colored glyph: NSStatusBarButton.contentTintColor is not a
// reliable way to override a template image's appearance on every macOS theme.
// This affects only the icon; the listener count remains native black/white.
private enum PortPulseStatusIcon {
    enum State: Equatable { case normal, network, error }

    static func image(for state: State) -> NSImage? {
        if state == .normal {
            let symbol = NSImage(systemSymbolName: "network", accessibilityDescription: "PortPulse")
            symbol?.isTemplate = true
            return symbol
        }

        let color: NSColor = state == .network ? .systemOrange : .systemRed
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            // Small vector globe designed for 18x18 status-bar rendering.
            // Drawing explicit strokes preserves semantic orange/red colors
            // without forcing the status button's count to be colored.
            color.setStroke()
            let outer = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            outer.lineWidth = 1.35
            outer.stroke()

            let meridian = NSBezierPath(ovalIn: NSRect(x: rect.midX - 3.0,
                                                        y: rect.minY + 2.5,
                                                        width: 6.0,
                                                        height: rect.height - 5.0))
            meridian.lineWidth = 1.0
            meridian.stroke()

            let equator = NSBezierPath()
            equator.move(to: NSPoint(x: rect.minX + 2.8, y: rect.midY))
            equator.line(to: NSPoint(x: rect.maxX - 2.8, y: rect.midY))
            equator.lineWidth = 1.0
            equator.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

final class PortPulseApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let controller = PortPulseViewController()
    private let queue = DispatchQueue(label: "com.daniele.portpulse.scan", qos: .utility)
    private let inspectQueue = DispatchQueue(label: "com.daniele.portpulse.inspect", qos: .userInitiated)
    private var timer: Timer?
    private var scanning = false
    private var listeners: [PortListener] = []
    private var diff = PortPulseDiff()
    private var iconState: PortPulseStatusIcon.State = .normal

    // Only replace the image when its semantic state actually changes.
    private func setIconState(_ state: PortPulseStatusIcon.State) {
        guard state != iconState else { return }
        iconState = state
        statusItem.button?.image = PortPulseStatusIcon.image(for: state)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 426, height: 590)
        popover.contentViewController = controller
        controller.onQuit = { NSApp.terminate(nil) }
        controller.onRefresh = { [weak self] in self?.refresh() }
        controller.onStop = { [weak self] listener in self?.terminate(listener) }
        controller.onStopGroup = { [weak self] group, filter, query in
            self?.terminateGroup(group, filter: filter, search: query)
        }
        controller.onInspect = { [weak self] listener in
            self?.inspectQueue.async { [weak self] in
                let info = PortProcessInspector.inspect(listener)
                DispatchQueue.main.async { [weak self] in
                    self?.controller.inspected(info, for: listener)
                }
            }
        }
        if let button = statusItem.button {
            button.image = PortPulseStatusIcon.image(for: .normal)
            // Do not tint the entire button; the 41-style count should always
            // adopt the menu bar's native readable foreground.
            button.contentTintColor = nil
            button.title = " …"
            button.target = self
            button.action = #selector(toggle)
            button.toolTip = "PortPulse: TCP in ascolto"
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        refresh()
    }

    @objc private func toggle() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Keep search accessible without forcing an electric-blue focus
            // ring before the user explicitly chooses to search.
            popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }

    private func refresh() {
        guard !scanning else { return }
        scanning = true
        queue.async { [weak self] in
            let outcome = Result { try PortScanner.scan() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                switch outcome {
                case .success(let found):
                    self.listeners = found
                    let added = self.diff.newNetworkListeners(found)
                    self.controller.render(found, newExposures: added, error: nil)
                    self.statusItem.button?.title = " \(PortPulseSummary(found).total)"
                    self.setIconState(found.contains(where: { $0.scope == .network })
                        ? .network : .normal)
                    self.statusItem.button?.toolTip =
                        "PortPulse · \(PortPulseSummary(found).total) porte TCP · \(PortPulseSummary(found).network) rete"
                case .failure(let error):
                    self.controller.render(self.listeners, newExposures: [], error: error.localizedDescription)
                    self.statusItem.button?.title = " !"
                    self.setIconState(.error)
                    self.statusItem.button?.toolTip = "PortPulse: \(error.localizedDescription)"
                }
            }
        }
    }


    private func terminateGroup(_ selected: PortGroup, filter: Int, search: String) {
        controller.showActionResult("Verifica di \(selected.pids.count) processi…")
        queue.async { [weak self] in
            let result: String
            do {
                let all = try PortScanner.scan()
                // Reproduce precisely the filter/search snapshot shown at
                // confirmation. A changed or partially visible group aborts
                // the whole operation BEFORE any signal is sent.
                let displayed = all.filter {
                    PortPulseCore.matches($0, filter: filter, search: search)
                }
                let fresh = PortPulseGrouping.groups(displayed)
                    .first(where: { $0.key == selected.key })
                guard PortPulseGrouping.validateStop(selected, against: fresh,
                                                     currentUID: Int(getuid()),
                                                     ownPID: getpid()) else {
                    throw PortScanner.ScanError.unavailable(
                        "Il gruppo è cambiato o include processi non consentiti. Nessun arresto eseguito."
                    )
                }
                var sent = 0
                var failed = 0
                for pid in selected.pids {
                    if Darwin.kill(pid, SIGTERM) == 0 {
                        sent += 1
                    } else {
                        failed += 1
                    }
                }
                result = failed == 0
                    ? "SIGTERM inviato a \(sent) processi"
                    : "SIGTERM: \(sent) inviati, \(failed) non riusciti"
            } catch {
                result = error.localizedDescription
            }
            DispatchQueue.main.async {
                self?.controller.showActionResult(result)
                self?.refresh()
            }
        }
    }

    private func terminate(_ listener: PortListener) {
        guard PortPulseCore.canTerminate(listener, currentUID: Int(getuid()), ownPID: getpid()) else { return }
        controller.showActionResult("Verifica processo in corso…")
        queue.async { [weak self] in
            let outcome: String
            do {
                let fresh = try PortScanner.scan()
                // Recheck endpoint, UID and command to avoid stopping a recycled PID.
                guard fresh.contains(where: {
                    $0.pid == listener.pid && $0.command == listener.command &&
                    $0.uid == listener.uid && $0.host == listener.host && $0.port == listener.port
                }) else {
                    throw PortScanner.ScanError.unavailable("Processo o porta cambiati: arresto annullato.")
                }
                if Darwin.kill(listener.pid, SIGTERM) == 0 {
                    outcome = "SIGTERM inviato al PID \(listener.pid)"
                } else {
                    outcome = "SIGTERM non riuscito (errno \(errno))"
                }
            } catch { outcome = error.localizedDescription }
            DispatchQueue.main.async {
                self?.controller.showActionResult(outcome)
                self?.refresh()
            }
        }
    }
}

#if !PORTPULSE_TEST
@main
struct PortPulseMain {
    static func main() {
        if CommandLine.arguments.contains("--help") {
            print("PortPulse: native macOS TCP listener menu-bar monitor. Usage: PortPulse [--help|--list].")
            return
        }
        if CommandLine.arguments.contains("--status-icon-test") {
            let normal = PortPulseStatusIcon.image(for: .normal)
            let warning = PortPulseStatusIcon.image(for: .network)
            let failure = PortPulseStatusIcon.image(for: .error)
            guard normal?.isTemplate == true,
                  warning?.isTemplate == false,
                  failure?.isTemplate == false,
                  warning?.size.width == 18,
                  failure?.size.height == 18 else {
                fputs("PortPulse menu bar icon appearance contract failed.\n", stderr)
                exit(EXIT_FAILURE)
            }
            print("PortPulse menu bar icon rendering contract passed.")
            return
        }
        if CommandLine.arguments.contains("--origin-smoke") {
            let own = PortListener(pid: getpid(), command: "PortPulse",
                                   uid: Int(getuid()), host: "127.0.0.1", port: 0)
            let info = PortProcessInspector.inspect(own)
            guard info.projectName != nil, info.elapsed != nil else {
                fputs("PortPulse process origin lookup failed for current user.\n", stderr)
                exit(EXIT_FAILURE)
            }
            print("PortPulse origin lookup passed: \(info.projectName ?? "")")
            return
        }
        if CommandLine.arguments.contains("--list") {
            do {
                for item in try PortScanner.scan() {
                    print("\(item.port)\t\(item.command)\tPID \(item.pid)\t\(item.address)")
                }
            } catch {
                fputs("PortPulse scan failed: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--ui-snapshot") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                fputs("Usage: PortPulse --ui-snapshot /path/to/output.png\n", stderr)
                exit(EXIT_FAILURE)
            }
            let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let controller = PortPulseViewController()
            let frame = NSRect(x: 0, y: 0, width: 426, height: 590)
            let window = NSWindow(contentRect: frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentViewController = controller
            window.orderFrontRegardless()
            let local: [PortListener] = [
                PortListener(pid: 69214, command: "node", uid: 501, host: "::1", port: 4000),
                PortListener(pid: 71597, command: "postgres", uid: 501, host: "127.0.0.1", port: 5432),
                PortListener(pid: 2375, command: "Google Drive", uid: 501, host: "::1", port: 7679),
                PortListener(pid: 702, command: "Spotify", uid: 501, host: "127.0.0.1", port: 7768),
                PortListener(pid: 28895, command: "llama-server", uid: 501, host: "127.0.0.1", port: 8091),
                PortListener(pid: 30357, command: "llama-server", uid: 501, host: "127.0.0.1", port: 8092),
                PortListener(pid: 57356, command: "llama-server", uid: 501, host: "127.0.0.1", port: 8093),
                PortListener(pid: 57431, command: "llama-server", uid: 501, host: "127.0.0.1", port: 8094),
                PortListener(pid: 64939, command: "llama-server", uid: 501, host: "127.0.0.1", port: 8095)
            ] + (0..<30).map {
                PortListener(pid: Int32(9000 + $0), command: "Dev service", uid: 501,
                             host: "127.0.0.1", port: 10000 + $0)
            }
            let network: [PortListener] = [
                PortListener(pid: 714, command: "ControlCenter", uid: 0, host: "*", port: 5000),
                PortListener(pid: 714, command: "ControlCenter", uid: 0, host: "*", port: 7000),
                PortListener(pid: 2000, command: "python", uid: 501, host: "0.0.0.0", port: 8000),
                PortListener(pid: 2001, command: "node", uid: 501, host: "::", port: 8080)
            ]
            let ordered = (local + network).sorted { $0.port < $1.port }
            controller.preview(ordered, expanded: local[0])
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            let bounds = controller.view.bounds
            guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: bounds) else {
                fputs("PortPulse snapshot bitmap allocation failed.\n", stderr)
                exit(EXIT_FAILURE)
            }
            controller.view.cacheDisplay(in: bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                fputs("PortPulse snapshot encoding failed.\n", stderr)
                exit(EXIT_FAILURE)
            }
            do { try png.write(to: destination) }
            catch {
                fputs("PortPulse snapshot write failed: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
            print("PortPulse UI screenshot written to \(destination.path)")
            return
        }
        let app = NSApplication.shared
        let delegate = PortPulseApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
#endif
#endif
