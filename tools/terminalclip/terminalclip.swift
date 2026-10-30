import Foundation

struct TerminalClipMetadata {
    let tty: String
    let directory: String
    let command: String
    let exitCode: Int
    let duration: Double
    let timestamp: Date

    init?(data: Data, expectedTTY: String) {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let p = raw.components(separatedBy: "\u{0}")
        guard p.count >= 6, p[0] == expectedTTY,
              let code = Int(p[3]), let seconds = Double(p[4]),
              seconds.isFinite, seconds >= 0,
              let epoch = Double(p[5]), epoch.isFinite, epoch > 0 else { return nil }
        tty = p[0]; directory = p[1]; command = p[2]
        exitCode = code; duration = seconds
        timestamp = Date(timeIntervalSince1970: epoch)
    }
}

enum TerminalClipText {
    // Removes common ANSI CSI and OSC escapes; not a full terminal emulator.
    static func clean(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var i = 0
        while i < chars.count {
            let v = chars[i].value
            if v == 27 {
                i += 1
                guard i < chars.count else { break }
                if chars[i].value == 91 {
                    i += 1
                    while i < chars.count {
                        let c = chars[i].value
                        i += 1
                        if c >= 64 && c <= 126 { break }
                    }
                } else if chars[i].value == 93 {
                    i += 1
                    while i < chars.count {
                        if chars[i].value == 7 { i += 1; break }
                        if chars[i].value == 27 && i+1 < chars.count && chars[i+1].value == 92 {
                            i += 2; break
                        }
                        i += 1
                    }
                } else { i += 1 }
                continue
            }
            if v == 8 { i += 1; continue }
            if v == 13 {
                result.append("\n".unicodeScalars.first!)
                if i+1 < chars.count && chars[i+1].value == 10 { i += 1 }
            } else { result.append(chars[i]) }
            i += 1
        }
        return String(result).trimmingCharacters(in: .newlines)
    }

    static func tail(_ text: String, count: Int) -> String {
        guard count > 0 else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(count).joined(separator: "\n")
    }

    static func report(_ metadata: TerminalClipMetadata, output: String) -> String {
        let date = ISO8601DateFormatter().string(from: metadata.timestamp)
        return """
        TerminalClip — Report diagnostico
        Data: \(date)
        Terminale: \(metadata.tty)
        Directory: \(metadata.directory)
        Comando: \(metadata.command)
        Exit code: \(metadata.exitCode)
        Durata: \(String(format: "%.2f", metadata.duration))s

        --- OUTPUT ---
        \(clean(output))
        """
    }
}

#if !TERMINALCLIP_TEST
import AppKit
import ApplicationServices
import Carbon

fileprivate enum ClipAction {
    case output, tail, command, directory, report
}

private func terminalClipHotkey(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let data = data else { return OSStatus(eventNotHandledErr) }
    let owner = Unmanaged<TerminalClipApp>.fromOpaque(data).takeUnretainedValue()
    DispatchQueue.main.async { owner.execute(.output) }
    return noErr
}


// MARK: - Native action rows (compact, keyboard-first)

private final class ClipActionRow: NSView {
    private let isPrimary: Bool
    private var pointerInside = false
    private var hoverArea: NSTrackingArea?

    init(title: String, detail: String, symbol: String, shortcut: String = "",
         primary: Bool = false, target: AnyObject, action: Selector) {
        isPrimary = primary
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10

        let symbolView = NSImageView()
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = primary ? .controlAccentColor : .secondaryLabelColor

        let titleView = NSTextField(labelWithString: title)
        titleView.font = .systemFont(ofSize: 12.5, weight: primary ? .semibold : .medium)
        titleView.textColor = .labelColor
        titleView.lineBreakMode = .byTruncatingTail

        let detailView = NSTextField(labelWithString: detail)
        detailView.font = .systemFont(ofSize: 10.5)
        detailView.textColor = .secondaryLabelColor
        detailView.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [titleView, detailView])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let shortcutView = NSTextField(labelWithString: shortcut)
        shortcutView.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        shortcutView.textColor = .tertiaryLabelColor
        shortcutView.alignment = .right
        shortcutView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let hitArea = NSButton(title: "", target: target, action: action)
        hitArea.isBordered = false
        hitArea.isTransparent = true
        hitArea.toolTip = title + " — " + detail
        hitArea.setAccessibilityLabel(title)

        for view in [symbolView, labels, shortcutView, hitArea] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 51),
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            symbolView.heightAnchor.constraint(equalToConstant: 18),

            labels.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: shortcutView.leadingAnchor, constant: -10),

            shortcutView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            shortcutView.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutView.leadingAnchor.constraint(greaterThanOrEqualTo: labels.trailingAnchor, constant: 10),

            hitArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            hitArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            hitArea.topAnchor.constraint(equalTo: topAnchor),
            hitArea.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        refreshStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refreshStyle() {
        let color: NSColor
        if isPrimary {
            color = NSColor.controlAccentColor.withAlphaComponent(pointerInside ? 0.20 : 0.12)
        } else {
            color = NSColor.controlColor.withAlphaComponent(pointerInside ? 0.75 : 0.34)
        }
        layer?.backgroundColor = color.cgColor
    }

    override func updateTrackingAreas() {
        if let area = hoverArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        refreshStyle()
    }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        refreshStyle()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyle()
    }
}

private final class OpaqueClipPanel: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

final class TerminalClipApp: NSObject {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var hotkey: EventHotKeyRef?
    private var hotkeyHandler: EventHandlerRef?
    private var copying = false
    private var feedbackSequence = 0
    private let info = NSTextField(labelWithString: "Locale · nessuna cronologia dell’output")
    private let sourceStatus = NSTextField(labelWithString: "Terminal.app")
    private let sourceDot = NSImageView()

    override init() {
        super.init()
        let button = status.button
        button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "TerminalClip")
        button?.toolTip = "TerminalClip · ⌘⌥C per copiare l'output"
        button?.target = self
        button?.action = #selector(togglePopover)
        let controller = NSViewController()
        controller.view = createPanel()
        popover.contentViewController = controller
        popover.behavior = .transient
        installHotkey()
    }

    private func createPanel() -> NSView {
        // Deliberately opaque rather than using a translucent NSMenu or vibrancy.
        let root = OpaqueClipPanel(frame: NSRect(x: 0, y: 0, width: 390, height: 460))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layer?.cornerRadius = 12

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                   color: NSColor = .labelColor) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.lineBreakMode = .byTruncatingTail
            return field
        }
        func sectionLabel(_ text: String) -> NSTextField {
            return label(text, size: 10, weight: .semibold, color: .tertiaryLabelColor)
        }
        func symbol(_ name: String, tint: NSColor = .secondaryLabelColor) -> NSImageView {
            let view = NSImageView()
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            view.imageScaling = .scaleProportionallyDown
            view.contentTintColor = tint
            return view
        }

        let headerIcon = symbol("terminal.fill", tint: .controlAccentColor)
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerIcon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        headerIcon.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let heading = label("TerminalClip", size: 16, weight: .semibold)
        let version = label("v0.2", size: 10, weight: .semibold,
                            color: .secondaryLabelColor)
        version.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleLine = NSStackView(views: [heading, version])
        titleLine.orientation = .horizontal
        titleLine.alignment = .centerY
        titleLine.spacing = 8
        let tagline = label("Dall'output agli appunti in un clic", size: 11,
                            weight: .regular, color: .secondaryLabelColor)
        let headingText = NSStackView(views: [titleLine, tagline])
        headingText.orientation = .vertical
        headingText.alignment = .leading
        headingText.spacing = 2
        let header = NSStackView(views: [headerIcon, headingText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        sourceDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        sourceDot.contentTintColor = .systemGreen
        sourceDot.translatesAutoresizingMaskIntoConstraints = false
        sourceDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        sourceDot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        sourceStatus.font = .systemFont(ofSize: 11, weight: .medium)
        sourceStatus.textColor = .secondaryLabelColor
        let sourceStack = NSStackView(views: [sourceDot, sourceStatus])
        sourceStack.orientation = .horizontal
        sourceStack.alignment = .centerY
        sourceStack.spacing = 7

        let titleQuick = sectionLabel("OUTPUT")
        let titleContext = sectionLabel("CONTESTO · RICHIEDE ZSH")

        let actions = NSStackView()
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 5
        for row in [
            ClipActionRow(title: "Copia ultimo output",
                          detail: "Il blocco dell'ultimo comando",
                          symbol: "doc.on.doc.fill", shortcut: "⌘⌥C",
                          primary: true, target: self, action: #selector(copyOutput)),
            ClipActionRow(title: "Ultime 100 righe",
                          detail: "Solo la parte finale dei log",
                          symbol: "text.alignleft", target: self, action: #selector(copyTail))
        ] {
            actions.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true
        }

        let context = NSStackView()
        context.orientation = .vertical
        context.alignment = .leading
        context.spacing = 5
        for row in [
            ClipActionRow(title: "Report diagnostico",
                          detail: "Comando, esito, durata e output",
                          symbol: "doc.text.magnifyingglass",
                          target: self, action: #selector(copyReport)),
            ClipActionRow(title: "Ultimo comando",
                          detail: "Testo del comando eseguito",
                          symbol: "chevron.left.forwardslash.chevron.right",
                          target: self, action: #selector(copyCommand)),
            ClipActionRow(title: "Directory corrente",
                          detail: "Percorso di lavoro dell'ultima esecuzione",
                          symbol: "folder",
                          target: self, action: #selector(copyDirectory))
        ] {
            context.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: context.widthAnchor).isActive = true
        }

        info.font = .systemFont(ofSize: 10.5)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        info.stringValue = "Locale · nessuna cronologia dell'output"
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let quit = NSButton(title: "Esci", target: self, action: #selector(quitApp))
        quit.bezelStyle = .inline
        quit.font = .systemFont(ofSize: 11)
        quit.setContentCompressionResistancePriority(.required, for: .horizontal)

        let footer = NSStackView(views: [info, quit])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.spacing = 10

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for (view, gap) in [(header as NSView, CGFloat(12)),
                            (sourceStack as NSView, CGFloat(17)),
                            (titleQuick as NSView, CGFloat(7)),
                            (actions as NSView, CGFloat(17)),
                            (titleContext as NSView, CGFloat(7)),
                            (context as NSView, CGFloat(14)),
                            (separator as NSView, CGFloat(9)),
                            (footer as NSView, CGFloat(0))] {
            stack.addArrangedSubview(view)
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            stack.setCustomSpacing(gap, after: view)
        }
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 390),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 15),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -15),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -13)
        ])
        return root
    }

    private func refreshSourceStatus() {
        let running = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Terminal").isEmpty
        sourceStatus.stringValue = running
            ? "Terminal.app disponibile"
            : "Terminal.app non aperto"
        sourceStatus.textColor = running ? .secondaryLabelColor : .systemOrange
        sourceDot.contentTintColor = running ? .systemGreen : .systemOrange
    }

    private func installHotkey() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let install = InstallEventHandler(GetApplicationEventTarget(), terminalClipHotkey,
                                          1, &type, pointer, &hotkeyHandler)
        guard install == noErr else { info.stringValue = "Shortcut non disponibile"; return }
        let id = EventHotKeyID(signature: 0x54434C50, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(cmdKey | optionKey),
                                         id, GetApplicationEventTarget(), 0, &hotkey)
        if result != noErr { info.stringValue = "⌘⌥C occupata: usa il menu" }
    }

    @objc private func togglePopover() {
        guard let button = status.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            refreshSourceStatus()
            popover.contentSize = popover.contentViewController?.view.fittingSize ?? NSSize(width: 390, height: 460)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    @objc private func copyOutput() { execute(.output) }
    @objc private func copyTail() { execute(.tail) }
    @objc private func copyReport() { execute(.report) }
    @objc private func copyCommand() { execute(.command) }
    @objc private func copyDirectory() { execute(.directory) }
    @objc private func quitApp() { NSApp.terminate(nil) }

    fileprivate func execute(_ action: ClipAction) {
        guard !copying else { return }
        if popover.isShown { popover.performClose(nil) }
        if case .command = action {
            guard let m = currentMetadata() else { feedback("Attiva Zsh e consenti Automazione", false); return }
            clipboard(m.command); feedback("Comando copiato", true); return
        }
        if case .directory = action {
            guard let m = currentMetadata() else { feedback("Attiva Zsh e consenti Automazione", false); return }
            clipboard(m.directory); feedback("Directory copiata", true); return
        }

        var metadata: TerminalClipMetadata?
        if case .report = action {
            metadata = currentMetadata()
            guard metadata != nil else { feedback("Report: integra Zsh e consenti Automazione", false); return }
        }
        capture { [weak self] raw in
            guard let self = self else { return }
            guard let raw = raw else { self.feedback("Output non trovato: verifica i marcatori", false); return }
            let clean = TerminalClipText.clean(raw)
            let result: String
            switch action {
            case .output: result = clean
            case .tail: result = TerminalClipText.tail(clean, count: 100)
            case .report: result = TerminalClipText.report(metadata!, output: raw)
            default: return
            }
            guard !result.isEmpty else { self.feedback("Output vuoto", false); return }
            self.clipboard(result)
            self.feedback("Copiato", true)
        }
    }

    private func currentMetadata() -> TerminalClipMetadata? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty else { return nil }
        let source = "tell application id \"com.apple.Terminal\" to get tty of selected tab of front window"
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        guard let value = script.executeAndReturnError(&error).stringValue else { return nil }
        let tty = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let basename = (tty as NSString).lastPathComponent
        guard tty.hasPrefix("/dev/"),
              basename.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TerminalClip/state/\(basename).dat")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return TerminalClipMetadata(data: data, expectedTTY: tty)
    }

    private func capture(_ finished: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted() else {
            let settings = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(settings)
            feedback("Consenti Accessibilità e riprova", false)
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else {
            feedback("Apri Terminal.app prima", false)
            return
        }
        copying = true
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            _ = app.activate(options: [.activateIgnoringOtherApps])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.sendKey(CGKeyCode(kVK_ANSI_A), modifiers: [.maskCommand, .maskShift])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                self?.sendKey(CGKeyCode(kVK_ANSI_C), modifiers: [.maskCommand])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                    guard let self = self else { return }
                    self.copying = false
                    guard pasteboard.changeCount != before else { finished(nil); return }
                    let text = pasteboard.string(forType: .string)
                    finished(text?.isEmpty == false ? text : nil)
                }
            }
        }
    }

    private func sendKey(_ key: CGKeyCode, modifiers: CGEventFlags) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
        down.flags = modifiers; up.flags = modifiers
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    private func clipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    private func feedback(_ message: String, _ success: Bool) {
        feedbackSequence += 1
        let sequence = feedbackSequence
        info.stringValue = message
        status.button?.image = NSImage(
            systemSymbolName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.feedbackSequence == sequence else { return }
            self.status.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "TerminalClip")
        }
    }
    deinit {
        if let key = hotkey { UnregisterEventHotKey(key) }
        if let handler = hotkeyHandler { RemoveEventHandler(handler) }
    }
}

let _ = {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let terminalClip = TerminalClipApp()
    application.run()
    withExtendedLifetime(terminalClip) {}
}()
#endif
