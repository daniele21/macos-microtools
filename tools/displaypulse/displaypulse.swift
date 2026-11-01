import AppKit
import Foundation

// DisplayPulse — a small, native macOS menu-bar brightness controller.
// DDC/CI uses the optional m1ddc executable; the software mode is self-contained.

private enum DDC {
    struct Probe {
        let current: Int
        let maximum: Int
    }

    enum Failure: Error, LocalizedError {
        case missingTool
        case invalidSelector
        case command(String)
        case invalidReading

        var errorDescription: String? {
            switch self {
            case .missingTool: return "m1ddc non trovato: brew install m1ddc"
            case .invalidSelector: return "Identificatore monitor non valido."
            case .command(let message): return "DDC non disponibile: \(message)"
            case .invalidReading: return "Il monitor non ha restituito una luminosità valida."
            }
        }
    }

    static func validSelector(_ selector: String) -> Bool {
        let chars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-:_=")
        return !selector.isEmpty && selector.count <= 128 &&
            selector.rangeOfCharacter(from: chars.inverted) == nil
    }

    static func binary() -> URL? {
        var candidates = ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/m1ddc" }
        }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return URL(fileURLWithPath: found)
    }

    static func run(_ arguments: [String]) throws -> String {
        guard let binary = binary() else { throw Failure.missingTool }
        let task = Process()
        task.executableURL = binary
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() }
        catch { throw Failure.command(error.localizedDescription) }

        // Never leave a hung external-display command running indefinitely.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
            if task.isRunning { task.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard task.terminationStatus == 0 else {
            throw Failure.command(String(output.prefix(180)))
        }
        return output
    }

    static func list() throws -> String {
        try run(["display", "list", "detailed"])
    }

    static func probe(_ selector: String) throws -> Probe {
        guard validSelector(selector) else { throw Failure.invalidSelector }
        let raw = try run(["display", selector, "get", "luminance"])
        guard let current = Int(raw), current >= 0, current <= 65535 else {
            throw Failure.invalidReading
        }
        let rawMax = try? run(["display", selector, "max", "luminance"])
        let maximum = max(1, Int(rawMax ?? "") ?? 100)
        return Probe(current: current, maximum: maximum)
    }

    static func write(_ selector: String, value: Int) throws {
        guard validSelector(selector) else { throw Failure.invalidSelector }
        _ = try run(["display", selector, "set", "luminance", String(value)])
    }
}

private final class SoftwareDimmer {
    private var window: NSWindow?

    func clear() {
        window?.orderOut(nil)
        window = nil
    }

    func set(percent: Int, screen: NSScreen?) {
        clear()
        guard let screen, percent < 100 else { return }
        let panel = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .black
        panel.alphaValue = CGFloat(100 - percent) / 100.0 * 0.85
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.orderFrontRegardless()
        window = panel
    }
}

private final class BrightnessController: NSViewController {
    private var mode: Int = 1 // 0: hardware, 1: software
    private var tested = false
    private var verifiedSelector: String?
    private let ddcQueue = DispatchQueue(label: "displaypulse.ddc", qos: .utility)
    private var maxDDCValue = 100
    private var pendingWrite: DispatchWorkItem?
    private var screens: [NSScreen] = []
    private let dimmer = SoftwareDimmer()
    var onPercentChange: ((Int) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "DisplayPulse")
    private let infoLabel = NSTextField(labelWithString: "Atlantis A05-P156WP · USB-C")
    private let modeControl = NSSegmentedControl(labels: ["Hardware", "Software"], trackingMode: .selectOne, target: nil, action: nil)
    private let slider = NSSlider(value: 100, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "100%")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Software: nessun oscuramento attivo.")
    private let targetField = NSTextField(string: "1")
    private let screenPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let probeButton = NSButton(title: "Verifica DDC/CI", target: nil, action: nil)
    private let listButton = NSButton(title: "Copia elenco", target: nil, action: nil)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 346, height: 300))
        self.view = root

        titleLabel.font = .boldSystemFont(ofSize: 15)
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3

        modeControl.selectedSegment = 1
        modeControl.setEnabled(false, forSegment: 0)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        slider.target = self
        slider.action = #selector(sliderChanged)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        targetField.placeholderString = "1"
        targetField.toolTip = "Numero o UUID di m1ddc display list detailed"
        targetField.alignment = .center
        targetField.widthAnchor.constraint(equalToConstant: 66).isActive = true
        targetField.target = self
        targetField.action = #selector(targetChanged)

        probeButton.target = self
        probeButton.action = #selector(probeClicked)
        listButton.target = self
        listButton.action = #selector(listClicked)

        let sliderRow = row([slider, valueLabel])
        let targetRow = row([label("DDC display:"), targetField, probeButton])
        let screenRow = row([label("Schermo software:"), screenPopup])
        screenPopup.target = self
        screenPopup.action = #selector(screenChanged)

        let quitButton = NSButton(title: "Esci", target: self, action: #selector(quitClicked))
        quitButton.bezelStyle = .inline

        let bottom = row([listButton, NSView(), quitButton])
        let stack = NSStackView(views: [
            titleLabel, infoLabel, modeControl, sliderRow,
            targetRow, screenRow, statusLabel, bottom
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
            sliderRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modeControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            screenRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refreshScreens()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    private func label(_ value: String) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 11)
        return field
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func refreshScreens() {
        let previous = screenPopup.selectedItem?.title
        screens = NSScreen.screens
        screenPopup.removeAllItems()
        for (index, screen) in screens.enumerated() {
            screenPopup.addItem(withTitle: "\(index + 1). \(screen.localizedName)")
        }
        if let previous, let idx = screenPopup.itemTitles.firstIndex(of: previous) {
            screenPopup.selectItem(at: idx)
        } else if let idx = screens.firstIndex(where: {
            $0.localizedName.localizedCaseInsensitiveContains("A05") ||
            $0.localizedName.localizedCaseInsensitiveContains("P156")
        }) {
            screenPopup.selectItem(at: idx)
        } else if previous == nil && !screens.isEmpty {
            screenPopup.selectItem(at: 0)
        } else {
            // Do not silently move the dimmer to a different screen after unplugging.
            screenPopup.select(nil)
        }
    }

    @objc private func screensChanged() {
        refreshScreens()
        if mode == 1 { applySoftware() }
    }

    @objc private func screenChanged() {
        if mode == 1 { applySoftware() }
    }

    @objc private func targetChanged() {
        verifiedSelector = nil
        tested = false
        modeControl.setEnabled(false, forSegment: 0)
        modeControl.selectedSegment = 1
        mode = 1
        statusLabel.stringValue = "Nuovo display: ripetere la verifica DDC."
        slider.doubleValue = 100
        valueLabel.stringValue = "100%"
        dimmer.clear()
    }

    @objc private func listClicked() {
        statusLabel.stringValue = "Ricerca monitor in corso…"
        ddcQueue.async {
            do {
                let text = try DDC.list()
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.statusLabel.stringValue = "Elenco monitor copiato negli appunti."
                }
            } catch {
                DispatchQueue.main.async { self.statusLabel.stringValue = error.localizedDescription }
            }
        }
    }

    @objc private func probeClicked() {
        let selector = targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tested = false
        verifiedSelector = nil
        modeControl.setEnabled(false, forSegment: 0)
        probeButton.isEnabled = false
        statusLabel.stringValue = "Lettura hardware in corso, nessuna modifica."
        ddcQueue.async {
            let result = Result { try DDC.probe(selector) }
            DispatchQueue.main.async {
                self.probeButton.isEnabled = true
                guard selector == self.targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                switch result {
                case .success(let response):
                    self.tested = true
                    self.verifiedSelector = selector
                    self.maxDDCValue = response.maximum
                    self.modeControl.setEnabled(true, forSegment: 0)
                    self.statusLabel.stringValue = "DDC letto: \(response.current)/\(response.maximum). Prova la modifica per confermare."
                    self.mode = 0
                    self.modeControl.selectedSegment = 0
                    self.dimmer.clear()
                    let percent = Int((Double(response.current) / Double(response.maximum) * 100).rounded())
                    self.slider.integerValue = min(100, max(10, percent))
                    self.updatePercentage()
                case .failure(let error):
                    self.mode = 1
                    self.modeControl.selectedSegment = 1
                    self.statusLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func modeChanged() {
        if modeControl.selectedSegment == 0 && !tested {
            modeControl.selectedSegment = 1
            return
        }
        pendingWrite?.cancel()
        mode = modeControl.selectedSegment
        dimmer.clear()
        if mode == 1 {
            slider.integerValue = 100
            statusLabel.stringValue = "Software: oscuramento visivo, non modifica la retroilluminazione."
        } else {
            statusLabel.stringValue = "Hardware: DDC/CI disponibile in lettura."
        }
        updatePercentage()
    }

    @objc private func sliderChanged() {
        updatePercentage()
        if mode == 1 {
            applySoftware()
        } else {
            pendingWrite?.cancel()
            let task = DispatchWorkItem { [weak self] in self?.sendHardwareValue() }
            pendingWrite = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
        }
    }

    private func updatePercentage() {
        let percent = slider.integerValue
        valueLabel.stringValue = "\(percent)%"
        onPercentChange?(percent)
    }

    private func applySoftware() {
        guard mode == 1 else { return }
        let index = screenPopup.indexOfSelectedItem
        let screen = screens.indices.contains(index) ? screens[index] : nil
        dimmer.set(percent: slider.integerValue, screen: screen)
    }

    private func sendHardwareValue() {
        guard tested, mode == 0 else { return }
        let selector = targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selector == verifiedSelector else {
            tested = false
            verifiedSelector = nil
            mode = 1
            modeControl.selectedSegment = 1
            modeControl.setEnabled(false, forSegment: 0)
            statusLabel.stringValue = "Monitor modificato: ripetere la verifica DDC."
            return
        }
        let percent = slider.integerValue
        let value = max(0, min(maxDDCValue, Int((Double(percent) / 100 * Double(maxDDCValue)).rounded())))
        ddcQueue.async {
            let result = Result { try DDC.write(selector, value: value) }
            DispatchQueue.main.async {
                guard self.mode == 0 && selector == self.targetField.stringValue else { return }
                switch result {
                case .success:
                    self.statusLabel.stringValue = "Comando inviato: \(percent)%. Conferma visivamente il cambiamento."
                case .failure(let error):
                    self.statusLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func quitClicked() {
        pendingWrite?.cancel()
        dimmer.clear()
        NSApp.terminate(nil)
    }
}

private final class DisplayPulseApp: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let controller = BrightnessController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 346, height: 300)
        popover.contentViewController = controller
        controller.onPercentChange = { [weak self] percentage in
            self?.item.button?.toolTip = "DisplayPulse · \(percentage)%"
        }
        if let button = item.button {
            let icon = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "DisplayPulse")
            icon?.isTemplate = true
            button.image = icon
            button.action = #selector(togglePopover)
            button.target = self
            button.toolTip = "DisplayPulse"
        }
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

@main
private struct DisplayPulseMain {
    static func main() {
        if CommandLine.arguments.contains("--help") {
            print("DisplayPulse: menu-bar brightness controller\nUsage: DisplayPulse [--probe DISPLAY]\n--probe reads hardware brightness without changing it.")
            return
        }
        if CommandLine.arguments.count >= 2 && CommandLine.arguments[1] == "--probe" {
            let identifier = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "1"
            do {
                print("Connected displays:\n\(try DDC.list())")
                let response = try DDC.probe(identifier)
                print("DDC readable: \(response.current)/\(response.maximum) on display \(identifier)")
            } catch {
                fputs("Probe failed: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = DisplayPulseApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
