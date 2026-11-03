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
    static func likelyHTTPURL(for listener: PortListener) -> URL? {
        let name = listener.command.lowercased()
        let candidates = ["node", "next", "vite", "uvicorn", "flask",
                          "httpd", "nginx", "caddy", "bun", "deno", "rails"]
        guard candidates.contains(where: name.contains) else { return nil }
        let ipv6 = listener.host.contains(":") && listener.host != "0.0.0.0"
        let host = ipv6 ? "[::1]" : "127.0.0.1"
        let scheme = listener.port == 443 ? "https" : "http"
        return URL(string: "\(scheme)://\(host):\(listener.port)")
    }

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

private final class PortPulseFlippedView: NSView {
    override var isFlipped: Bool { true }
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
    var onOpen: ((URL) -> Void)?

    private let titleField = NSTextField(labelWithString: "PortPulse")
    private let updatedField = NSTextField(labelWithString: "In attesa della prima scansione")
    private let totalMetric = NSTextField(labelWithString: "—")
    private let localMetric = NSTextField(labelWithString: "—")
    private let networkMetric = NSTextField(labelWithString: "—")
    private let eventField = NSTextField(wrappingLabelWithString: "")
    private let filter = NSSegmentedControl(labels: ["Tutte", "Locali", "Rete"],
                                            trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let rows = NSStackView()
    private let scroll = NSScrollView()
    private let footerField = NSTextField(labelWithString: "TCP · ogni 5 s")
    private var listeners: [PortListener] = []
    private var selectedID: String?
    private var lastError: String?
    private var latestEvent: PortListener?
    private var hasLoaded = false

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 426, height: 590))
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

        search.placeholderString = "Cerca porta, processo, PID"
        search.controlSize = .regular
        search.focusRingType = .default
        search.target = self
        search.action = #selector(filtersChanged)
        search.sendsSearchStringImmediately = true
        search.heightAnchor.constraint(equalToConstant: 28).isActive = true

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
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
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
                                          eventField, scroll, separator, footer])
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
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = radius
        box.layer?.backgroundColor = fill.cgColor
        box.layer?.borderColor = stroke.cgColor
        box.layer?.borderWidth = 1
        return box
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

        for (index, item) in filtered.enumerated() {
            let card = makeListenerCard(item, index: index)
            rows.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        view.layoutSubtreeIfNeeded()
        if let document = scroll.documentView {
            let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: resetScroll ? 0 : min(oldY, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func makeListenerCard(_ item: PortListener, index: Int) -> NSView {
        let selected = item.identifier == selectedID
        let tint: NSColor = item.scope == .local ? PortPulsePalette.green : PortPulsePalette.orange
        let card = surface(
            fill: NSColor.controlBackgroundColor.withAlphaComponent(selected ? 0.62 : 0.37),
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
        let process = label(item.command, size: 12, weight: .semibold)
        let metadata = label("\(item.host) · PID \(item.pid)", size: 10, color: .secondaryLabelColor)
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
        hit.setAccessibilityLabel("Porta \(item.port), \(item.command), \(item.scope == .local ? "locale" : "rete"), \(selected ? "chiudi" : "apri") dettagli")
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
            let detailBox = surface(fill: .secondaryLabelColor.withAlphaComponent(0.055),
                                    stroke: .separatorColor.withAlphaComponent(0.12), radius: 8)
            let address = label(item.address, size: 11, weight: .medium)
            address.lineBreakMode = .byTruncatingMiddle
            let addressColumn = vertical([
                label("INDIRIZZO", size: 9, color: .secondaryLabelColor),
                address
            ], spacing: 2)
            let pidColumn = vertical([
                label("PID", size: 9, color: .secondaryLabelColor),
                label("\(item.pid)", size: 11, weight: .medium)
            ], spacing: 2)
            let uidColumn = vertical([
                label("UID", size: 9, color: .secondaryLabelColor),
                label(item.uid.map(String.init) ?? "—", size: 11, weight: .medium)
            ], spacing: 2)
            let detailRow = horizontal([addressColumn, NSView(), pidColumn, uidColumn], spacing: 12)
            detailRow.translatesAutoresizingMaskIntoConstraints = false
            detailBox.addSubview(detailRow)
            NSLayoutConstraint.activate([
                detailRow.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 10),
                detailRow.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -10),
                detailRow.topAnchor.constraint(equalTo: detailBox.topAnchor, constant: 9),
                detailRow.bottomAnchor.constraint(equalTo: detailBox.bottomAnchor, constant: -9)
            ])
            elements.append(detailBox)

            let copy = smallButton("Copia", symbol: "doc.on.doc", action: #selector(copyClicked))
            var actions: [NSView] = [copy]
            if let url = PortPulseCore.likelyHTTPURL(for: item) {
                let open = smallButton("Apri HTTP", symbol: "arrow.up.right.square", action: #selector(openClicked))
                open.toolTip = "Prova ad aprire \(url.absoluteString) nel browser; protocollo non verificato"
                actions.append(open)
            }
            let stop = smallButton("Termina…", symbol: "stop.circle", action: #selector(stopClicked))
            stop.contentTintColor = .systemRed
            stop.isEnabled = PortPulseCore.canTerminate(item, currentUID: Int(getuid()), ownPID: getpid())
            stop.toolTip = stop.isEnabled ? "Invia SIGTERM dopo conferma" : "Solo processi verificati del tuo utente"
            actions.append(NSView())
            actions.append(stop)
            let actionRow = horizontal(actions, spacing: 7)
            elements.append(actionRow)
        }

        let inside = vertical(elements, spacing: selected ? 9 : 0)
        inside.alignment = .width
        inside.translatesAutoresizingMaskIntoConstraints = false
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
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        return button
    }

    @objc private func filtersChanged() { rebuild(resetScroll: true) }

    @objc private func rowClicked(_ sender: NSButton) {
        let filtered = visible
        guard filtered.indices.contains(sender.tag) else { return }
        let id = filtered[sender.tag].identifier
        selectedID = selectedID == id ? nil : id
        rebuild()
    }

    private var selected: PortListener? {
        listeners.first { $0.identifier == selectedID }
    }

    @objc private func copyClicked() {
        guard let item = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "\(item.command) · PID \(item.pid) · UID \(item.uid.map(String.init) ?? "—") · TCP \(item.address)",
            forType: .string
        )
        footerField.stringValue = "Dettagli copiati"
    }

    @objc private func openClicked() {
        guard let item = selected, let url = PortPulseCore.likelyHTTPURL(for: item) else { return }
        onOpen?(url)
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

final class PortPulseApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let controller = PortPulseViewController()
    private let queue = DispatchQueue(label: "com.daniele.portpulse.scan", qos: .utility)
    private var timer: Timer?
    private var scanning = false
    private var listeners: [PortListener] = []
    private var diff = PortPulseDiff()

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 426, height: 590)
        popover.contentViewController = controller
        controller.onQuit = { NSApp.terminate(nil) }
        controller.onRefresh = { [weak self] in self?.refresh() }
        controller.onStop = { [weak self] listener in self?.terminate(listener) }
        controller.onOpen = { [weak self] url in
            let launched = NSWorkspace.shared.open(url)
            self?.controller.showActionResult(launched ? "Apertura HTTP nel browser…" : "Impossibile aprire HTTP")
        }
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "network", accessibilityDescription: "PortPulse")
            image?.isTemplate = true
            button.image = image
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
                    self.statusItem.button?.contentTintColor =
                        found.contains(where: { $0.scope == .network }) ? .systemOrange : nil
                    self.statusItem.button?.toolTip =
                        "PortPulse · \(PortPulseSummary(found).total) porte TCP · \(PortPulseSummary(found).network) rete"
                case .failure(let error):
                    self.controller.render(self.listeners, newExposures: [], error: error.localizedDescription)
                    self.statusItem.button?.title = " !"
                    self.statusItem.button?.contentTintColor = .systemRed
                    self.statusItem.button?.toolTip = "PortPulse: \(error.localizedDescription)"
                }
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
        let app = NSApplication.shared
        let delegate = PortPulseApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
#endif
#endif
