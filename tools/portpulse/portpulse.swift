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

final class PortPulseViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onStop: ((PortListener) -> Void)?

    private let titleField = NSTextField(labelWithString: "PortPulse")
    private let summaryField = NSTextField(labelWithString: "Lettura in corso…")
    private let eventField = NSTextField(wrappingLabelWithString: "")
    private let filter = NSSegmentedControl(labels: ["Tutte", "Locali", "Rete"],
                                            trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let rows = NSStackView()
    private let statusField = NSTextField(labelWithString: "Monitoraggio TCP · ogni 5 s")
    private var listeners: [PortListener] = []
    private var selectedID: String?
    private var lastError: String?
    private var lastEvent: String?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 515))
        view = root

        titleField.font = .boldSystemFont(ofSize: 16)
        summaryField.font = .systemFont(ofSize: 12, weight: .medium)
        summaryField.textColor = .secondaryLabelColor
        eventField.font = .systemFont(ofSize: 11)
        eventField.textColor = .systemOrange
        eventField.maximumNumberOfLines = 2
        eventField.isHidden = true
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(filtersChanged)
        search.placeholderString = "Cerca porta o processo"
        search.target = self
        search.action = #selector(filtersChanged)
        search.sendsSearchStringImmediately = true
        rows.orientation = .vertical
        rows.spacing = 7
        rows.alignment = .width
        rows.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let refresh = NSButton(title: "Aggiorna", target: self, action: #selector(refreshClicked))
        refresh.bezelStyle = .rounded
        let quit = NSButton(title: "Esci", target: self, action: #selector(quitClicked))
        quit.bezelStyle = .rounded
        statusField.font = .systemFont(ofSize: 10)
        statusField.textColor = .tertiaryLabelColor
        let footer = horizontal([statusField, NSView(), refresh, quit])
        let column = NSStackView(views: [titleField, summaryField, eventField, filter, search, scroll, footer])
        column.orientation = .vertical
        column.spacing = 11
        column.alignment = .width
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 15),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func label(_ text: String, size: CGFloat = 11, color: NSColor = .labelColor) -> NSTextField {
        let result = NSTextField(labelWithString: text)
        result.font = .systemFont(ofSize: size)
        result.textColor = color
        result.lineBreakMode = .byTruncatingMiddle
        return result
    }

    func render(_ items: [PortListener], newExposures: [PortListener], error: String?) {
        listeners = items
        lastError = error
        if let added = newExposures.first {
            lastEvent = "Nuova porta non locale: \(added.address) · \(added.command)"
        }
        rebuild()
    }

    private func rebuild() {
        let networkCount = listeners.filter { $0.scope == .network }.count
        let localCount = listeners.count - networkCount
        summaryField.stringValue = lastError ?? "\(listeners.count) listener · \(localCount) locali · \(networkCount) non locali"
        summaryField.textColor = lastError == nil ? .secondaryLabelColor : .systemRed
        eventField.stringValue = lastEvent ?? ""
        eventField.isHidden = lastEvent == nil

        rows.arrangedSubviews.forEach { item in
            rows.removeArrangedSubview(item)
            item.removeFromSuperview()
        }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = listeners.filter { item in
            let scopeMatches = filter.selectedSegment == 0 ||
                (filter.selectedSegment == 1 && item.scope == .local) ||
                (filter.selectedSegment == 2 && item.scope == .network)
            return scopeMatches && (query.isEmpty ||
                String(item.port).contains(query) ||
                item.command.lowercased().contains(query) ||
                item.host.lowercased().contains(query))
        }
        if visible.isEmpty {
            rows.addArrangedSubview(label(lastError == nil ? "Nessuna porta corrispondente." : "Dati non disponibili.", color: .secondaryLabelColor))
        }
        for (index, item) in visible.enumerated() {
            let dot = label(item.scope == .local ? "●" : "▲", size: 12,
                            color: item.scope == .local ? .systemGreen : .systemOrange)
            let name = NSButton(title: "\(item.port)   \(item.command)", target: self,
                                action: #selector(rowClicked(_:)))
            name.tag = index
            name.isBordered = false
            name.alignment = .left
            name.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            name.lineBreakMode = .byTruncatingTail
            let meta = label("\(item.host) · PID \(item.pid)", size: 10, color: .secondaryLabelColor)
            let entry = NSStackView(views: [horizontal([dot, name]), meta])
            entry.orientation = .vertical
            entry.alignment = .leading
            entry.spacing = 2
            rows.addArrangedSubview(entry)
            entry.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            if selectedID == item.identifier {
                let details = label("TCP  \(item.address) · UID \(item.uid.map(String.init) ?? "non disponibile")",
                                    size: 10, color: .secondaryLabelColor)
                let copy = NSButton(title: "Copia dettagli", target: self, action: #selector(copyClicked))
                let stop = NSButton(title: "Arresta…", target: self, action: #selector(stopClicked))
                stop.isEnabled = PortPulseCore.canTerminate(item, currentUID: Int(getuid()), ownPID: getpid())
                stop.toolTip = stop.isEnabled ? "Invia SIGTERM dopo conferma" : "Solo processi del tuo utente"
                let actions = horizontal([copy, stop])
                let expanded = NSStackView(views: [details, actions])
                expanded.orientation = .vertical
                expanded.alignment = .leading
                expanded.spacing = 5
                rows.addArrangedSubview(expanded)
                expanded.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }
    }

    @objc private func filtersChanged() { rebuild() }

    @objc private func rowClicked(_ sender: NSButton) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = listeners.filter { item in
            let matches = filter.selectedSegment == 0 ||
                (filter.selectedSegment == 1 && item.scope == .local) ||
                (filter.selectedSegment == 2 && item.scope == .network)
            return matches && (query.isEmpty || String(item.port).contains(query) ||
                item.command.lowercased().contains(query) || item.host.lowercased().contains(query))
        }
        guard visible.indices.contains(sender.tag) else { return }
        let id = visible[sender.tag].identifier
        selectedID = selectedID == id ? nil : id
        rebuild()
    }

    private var selected: PortListener? { listeners.first { $0.identifier == selectedID } }

    @objc private func copyClicked() {
        guard let item = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(item.command) · PID \(item.pid) · TCP \(item.address)", forType: .string)
        statusField.stringValue = "Dettagli copiati"
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

    func showActionResult(_ message: String) { statusField.stringValue = message }
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
        popover.contentSize = NSSize(width: 390, height: 515)
        popover.contentViewController = controller
        controller.onQuit = { NSApp.terminate(nil) }
        controller.onRefresh = { [weak self] in self?.refresh() }
        controller.onStop = { [weak self] listener in self?.terminate(listener) }
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
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
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
                    self.statusItem.button?.title = " \(found.count)"
                    self.statusItem.button?.contentTintColor =
                        found.contains(where: { $0.scope == .network }) ? .systemOrange : nil
                    self.statusItem.button?.toolTip =
                        "PortPulse · \(found.count) listener TCP · \(found.filter { $0.scope == .network }.count) non locali"
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

@main
struct PortPulseMain {
    static func main() {
        if CommandLine.arguments.contains("--help") {
            print("PortPulse: native macOS TCP listener menu-bar monitor.")
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
