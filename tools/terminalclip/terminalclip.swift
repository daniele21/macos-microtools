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

final class TerminalClipApp: NSObject {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var hotkey: EventHotKeyRef?
    private var hotkeyHandler: EventHandlerRef?
    private var copying = false
    private var feedbackSequence = 0
    private let info = NSTextField(labelWithString: "Solo Terminal.app · nessuna cattura continua")

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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 300))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let heading = NSTextField(labelWithString: "TerminalClip")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Copia dal tab corrente di Terminal.app")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(subtitle)

        let entries: [(String, String, Selector)] = [
            ("Copia ultimo output", "⌘⌥C", #selector(copyOutput)),
            ("Copia ultime 100 righe", "", #selector(copyTail)),
            ("Copia report diagnostico", "", #selector(copyReport)),
            ("Copia ultimo comando", "", #selector(copyCommand)),
            ("Copia directory", "", #selector(copyDirectory))
        ]
        for (title, shortcut, action) in entries {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fill
            row.spacing = 6
            let button = NSButton(title: title, target: self, action: action)
            button.font = .systemFont(ofSize: 12)
            button.bezelStyle = .rounded
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let hint = NSTextField(labelWithString: shortcut)
            hint.font = .systemFont(ofSize: 10)
            hint.textColor = .tertiaryLabelColor
            row.addArrangedSubview(button)
            row.addArrangedSubview(hint)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(info)
        let quit = NSButton(title: "Esci", target: self, action: #selector(quitApp))
        quit.bezelStyle = .inline
        stack.addArrangedSubview(quit)
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(equalToConstant: 350),
            root.heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor, constant: 24)
        ])
        return root
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
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
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
