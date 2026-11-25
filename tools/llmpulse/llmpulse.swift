#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import Combine

// One polling process and one provider store; each status item is only a view
// of that store. No extra daemons or provider sessions per menu bar item.
final class LLMPulseStore: ObservableObject {
    @Published var snapshots: [LLMProvider: QuotaSnapshot] = [:]
    @Published var errors: [LLMProvider: String] = [:]
    @Published var claudeLinkState: ClaudeLinkState = ClaudeStatusLineManager.status()
    @Published var claudeSetupError: String?
    @Published var refreshing: Set<LLMProvider> = []
    @Published private(set) var now = Date()
    @Published var autoRefresh: Bool {
        didSet { UserDefaults.standard.set(autoRefresh, forKey: "llmpulse.autoRefresh") }
    }
    @Published var showRemaining: Bool {
        didSet {
            UserDefaults.standard.set(showRemaining, forKey: "llmpulse.showRemaining")
            didUpdate?()
        }
    }
    @Published private(set) var visibleProviders: Set<LLMProvider> {
        didSet {
            UserDefaults.standard.set(
                LLMProvider.allCases.filter { !visibleProviders.contains($0) }.map(\.rawValue),
                forKey: "llmpulse.hiddenProviders"
            )
            didUpdate?()
        }
    }
    @Published var antigravityGroup: String {
        didSet {
            UserDefaults.standard.set(antigravityGroup, forKey: "llmpulse.antigravityGroup")
            didUpdate?()
        }
    }
    var didUpdate: (() -> Void)?
    private var refreshTimer: Timer?
    private var claudeTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        autoRefresh = (defaults.object(forKey: "llmpulse.autoRefresh") as? Bool) ?? true
        showRemaining = (defaults.object(forKey: "llmpulse.showRemaining") as? Bool) ?? false
        let hidden = Set((defaults.array(forKey: "llmpulse.hiddenProviders") as? [String]) ?? [])
        let enabled = LLMProvider.allCases.filter { !hidden.contains($0.rawValue) }
        // Preserve an escape route into Settings: never allow an empty menu bar.
        visibleProviders = Set(enabled.isEmpty ? LLMProvider.allCases : enabled)
        antigravityGroup = defaults.string(forKey: "llmpulse.antigravityGroup") ??
            QuotaPresentation.automaticGroup
        for provider in LLMProvider.allCases {
            let filename = provider == .claude ? "claude-quota.json" : "\(provider.rawValue).json"
            let file = QuotaFiles.directory().appendingPathComponent(filename)
            if let cached = QuotaFiles.read(at: file, provider: provider) {
                snapshots[provider] = cached
            }
        }
    }

    func start() {
        refreshAll()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self, self.autoRefresh else { return }
            self.refreshAll()
        }
        // Claude is updated externally by the lightweight statusLine helper.
        // Poll ONLY that private local file, never run a Claude CLI probe.
        claudeTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.observeClaudeFile()
            // Even without a new snapshot, a once-fresh quota eventually
            // becomes stale or passes its reset boundary.
            self.now = Date()
            self.didUpdate?()
        }
    }

    func isVisible(_ provider: LLMProvider) -> Bool { visibleProviders.contains(provider) }

    func setVisible(_ provider: LLMProvider, _ visible: Bool) {
        if visible {
            visibleProviders.insert(provider)
        } else if visibleProviders.count > 1 {
            visibleProviders.remove(provider)
        }
    }

    func inspectClaudeConnection() {
        claudeLinkState = ClaudeStatusLineManager.status()
    }

    // Explicitly user-triggered one-click connect. Never silently modifies
    // ~/.claude/settings.json when viewing a menu item or running auto refresh.
    func connectClaude() {
        do {
            claudeLinkState = try ClaudeStatusLineManager.connect()
            claudeSetupError = nil
        } catch {
            claudeSetupError = error.localizedDescription
            inspectClaudeConnection()
        }
        didUpdate?()
    }

    func refreshAll() {
        for provider in LLMProvider.allCases { refresh(provider) }
    }

    func refresh(_ provider: LLMProvider) {
        guard !refreshing.contains(provider) else { return }
        refreshing.insert(provider)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<QuotaSnapshot, Error>
            do { result = .success(try QuotaFetcher.fetch(provider)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing.remove(provider)
                switch result {
                case .success(let snapshot):
                    // A statusLine event may have arrived while this read ran.
                    // Do not let an older Claude snapshot replace newer quota data.
                    let existing = self.snapshots[provider]
                    if existing == nil || snapshot.capturedAt >= existing!.capturedAt {
                        self.snapshots[provider] = snapshot
                    }
                    self.errors.removeValue(forKey: provider)
                    if provider != .claude {
                        let file = QuotaFiles.directory()
                            .appendingPathComponent("\(provider.rawValue).json")
                        try? QuotaFiles.write(snapshot, at: file)
                    }
                case .failure(let error):
                    self.errors[provider] = error.localizedDescription
                }
                self.didUpdate?()
            }
        }
    }

    private func observeClaudeFile() {
        guard let fresh = QuotaFiles.read(at: QuotaFiles.claudeFile(), provider: .claude),
              fresh.capturedAt > (snapshots[.claude]?.capturedAt ?? .distantPast) else { return }
        snapshots[.claude] = fresh
        errors.removeValue(forKey: .claude)
        didUpdate?()
    }

    func fiveHour(_ provider: LLMProvider, now: Date? = nil) -> QuotaWindow? {
        QuotaPresentation.fiveHour(snapshots[provider], group: antigravityGroup,
                                   at: now ?? self.now)
    }

    func weekly(_ provider: LLMProvider, now: Date? = nil) -> QuotaWindow? {
        let effectiveTime = now ?? self.now
        let fiveHour = self.fiveHour(provider, now: effectiveTime)
        return QuotaPresentation.weekly(snapshots[provider], matching: fiveHour,
                                        group: antigravityGroup, at: effectiveTime)
    }

    var antigravityGroups: [String] {
        QuotaPresentation.groups(in: snapshots[.antigravity])
    }
}

private enum QuotaStyle {
    static func tint(remaining: Double) -> Color {
        if remaining <= 10 { return Color(red: 0.87, green: 0.37, blue: 0.33) }
        if remaining <= 25 { return Color(red: 0.88, green: 0.59, blue: 0.25) }
        return Color(red: 0.20, green: 0.65, blue: 0.57)
    }
    // Native adaptive macOS colors: stable identification even when a quota
    // has no data. Severity still overrides the numeric metric and gauge.
    static func brandTint(_ provider: LLMProvider) -> NSColor {
        switch provider {
        case .codex: return .systemTeal
        case .claude: return .systemOrange
        case .antigravity: return .systemIndigo
        }
    }
    static func statusTint(remaining: Double, provider: LLMProvider) -> NSColor {
        if remaining <= 10 { return .systemRed }
        if remaining <= 25 { return .systemOrange }
        return brandTint(provider)
    }
    static func symbol(_ provider: LLMProvider) -> String {
        switch provider {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "asterisk"
        case .antigravity: return "sparkles"
        }
    }
    static func age(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "adesso" }
        if seconds < 3600 { return "\(seconds / 60)m fa" }
        if seconds < 86400 { return "\(seconds / 3600)h fa" }
        return "\(seconds / 86400)g fa"
    }
    static func groupName(_ group: String) -> String {
        if group == "Gemini Models" { return "Gemini" }
        if group == "Claude and GPT models" { return "Claude / GPT" }
        return group
    }
}

// Purely decorative overlay. Mouse events pass to NSStatusBarButton.
private final class QuotaGauge: NSView {
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }
    var isAvailable = false { didSet { needsDisplay = true } }
    var fillColor = NSColor.controlAccentColor { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 0.5)
        let track = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
        NSColor.labelColor.withAlphaComponent(0.28).setFill()
        track.fill()
        guard isAvailable else { return }
        let fill = NSRect(x: rect.minX, y: rect.minY,
                          width: rect.width * max(0, min(1, progress)),
                          height: rect.height)
        fillColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
        // Outline keeps the accent readable even when its hue happens to
        // approach the luminosity of the translucent menu bar.
        NSColor.labelColor.withAlphaComponent(0.50).setStroke()
        track.lineWidth = 0.55
        track.stroke()
    }
}

private struct QuotaMeter: View {
    let quota: QuotaWindow?
    let showRemaining: Bool
    let large: Bool
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 10 : 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: large ? 12 : 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if large {
                        Text(showRemaining ? "Quota disponibile" : "Quota consumata")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(QuotaPresentation.usedLabel(quota, showRemaining: showRemaining))
                    .font(.system(size: large ? 31 : 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(quota.map { QuotaStyle.tint(remaining: $0.remainingPercent) } ??
                                    Color.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    if let quota {
                        Capsule()
                            .fill(QuotaStyle.tint(remaining: quota.remainingPercent))
                            .frame(width: geo.size.width *
                                CGFloat((showRemaining ? quota.remainingPercent : quota.usedPercent) / 100))
                    }
                }
            }
            .frame(height: large ? 7 : 5)
            HStack {
                Text(quota == nil ? "Dato non disponibile" :
                    (showRemaining ? "Disponibile" : "Utilizzato"))
                Spacer()
                if let quota {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        Text("Reset \(quota.resetDescription(now: timeline.date))")
                    }
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }
}

private struct GroupRow: View {
    @ObservedObject var store: LLMPulseStore
    let name: String

    private var sample: QuotaSnapshot? {
        guard let snapshot = store.snapshots[.antigravity] else { return nil }
        let groupWindows = snapshot.windows.filter {
            QuotaPresentation.group(of: $0, provider: .antigravity) == name
        }
        return QuotaSnapshot(provider: .antigravity, windows: groupWindows,
                             capturedAt: snapshot.capturedAt)
    }

    var body: some View {
        let selected = store.antigravityGroup == name
        let five = QuotaPresentation.fiveHour(sample, group: name)
        let week = QuotaPresentation.weekly(sample, matching: five, group: name)
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                store.antigravityGroup = name
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? QuotaStyle.tint(remaining: 80) : Color.secondary)
                Text(QuotaStyle.groupName(name))
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(QuotaPresentation.usedLabel(five, showRemaining: store.showRemaining))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("5h").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(width: 42, alignment: .trailing)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(QuotaPresentation.usedLabel(week, showRemaining: store.showRemaining))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("7gg").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(width: 42, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 5)
    }
}

// Explicit per-popover navigation state. Avoid the SwiftUI @State macro:
// newer standalone Command Line Tools SDKs can expose State as a macro while
// lacking the SwiftUIMacros compiler plugin. Combine's Published is a property
// wrapper, and ObservedObject is already used for the shared quota store.
// A new model is created every time a provider popover opens, preserving the
// former per-view lifetime without relying on SDK-specific macro expansion.
private final class LLMPulsePopoverNavigation: ObservableObject {
    @Published var showingSettings = false
    @Published var expanded = false
}

private struct LLMPulsePopover: View {
    @ObservedObject var store: LLMPulseStore
    let provider: LLMProvider
    @ObservedObject var navigation: LLMPulsePopoverNavigation

    private var snapshot: QuotaSnapshot? { store.snapshots[provider] }
    private var session: QuotaWindow? { store.fiveHour(provider) }
    private var weekly: QuotaWindow? { store.weekly(provider) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if navigation.showingSettings {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { navigation.showingSettings = false }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Image(systemName: QuotaStyle.symbol(provider))
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 9))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(navigation.showingSettings ? "Impostazioni" : provider.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(navigation.showingSettings ? "Preferenze LLMPulse" : provider.source)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !navigation.showingSettings {
                    if store.refreshing.contains(provider) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { store.refresh(provider) } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Aggiorna \(provider.title)")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()

            ScrollView {
                if navigation.showingSettings {
                    settingsContent
                } else {
                    providerContent
                }
            }
            Divider()

            HStack {
                if !navigation.showingSettings {
                    if let snapshot {
                        HStack(spacing: 5) {
                            Image(systemName: snapshot.isFresh(now: store.now) ? "checkmark.circle.fill" : "clock")
                                .foregroundStyle(snapshot.isFresh(now: store.now) ? Color.green : Color.orange)
                            Text(snapshot.isFresh(now: store.now) ? "Aggiornato \(QuotaStyle.age(snapshot.capturedAt))" :
                                "Dati precedenti · \(QuotaStyle.age(snapshot.capturedAt))")
                        }
                    } else {
                        Text("In attesa della prima lettura")
                    }
                } else {
                    Text("Un processo · tre indicatori")
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        navigation.showingSettings.toggle()
                    }
                } label: {
                    Image(systemName: navigation.showingSettings ? "checkmark" : "gearshape")
                }
                .buttonStyle(.borderless)
                .help(navigation.showingSettings ? "Chiudi impostazioni" : "Impostazioni")
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Esci da LLMPulse")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .frame(width: 364, height: 420)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var providerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if provider == .claude {
                claudeConnectionSection
            }
            if provider == .antigravity {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                    Text(store.antigravityGroup == QuotaPresentation.automaticGroup ?
                        "5h più limitante" :
                        QuotaStyle.groupName(store.antigravityGroup))
                    Spacer()
                    Text("Gruppo monitorato")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            QuotaMeter(quota: session, showRemaining: store.showRemaining,
                       large: true, label: "Finestra · 5 ore")
                .padding(13)
                .background(Color(NSColor.controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 13))
            QuotaMeter(quota: weekly, showRemaining: store.showRemaining,
                       large: false, label: "Finestra · settimanale")
                .padding(13)
                .background(Color(NSColor.controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 13))
            if let session, session.remainingPercent <= 25 {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Quota 5h quasi esaurita · \(Int(session.remainingPercent.rounded()))% disponibile")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(QuotaStyle.tint(remaining: session.remainingPercent))
            }
            if let error = store.errors[provider] {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { navigation.expanded.toggle() }
            } label: {
                HStack {
                    Text(provider == .antigravity ? "Gruppi e altre quote" : "Altre quote")
                    Spacer()
                    Image(systemName: navigation.expanded ? "chevron.up" : "chevron.down")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
            if navigation.expanded {
                if provider == .antigravity {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            store.antigravityGroup = QuotaPresentation.automaticGroup
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: store.antigravityGroup ==
                                    QuotaPresentation.automaticGroup ? "checkmark.circle.fill" : "circle")
                                Text("Automatico · 5h più limitante")
                            }
                            .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        ForEach(store.antigravityGroups, id: \.self) { group in
                            GroupRow(store: store, name: group)
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 10))
                } else if let snapshot {
                    let excluded = Set([session?.id, weekly?.id].compactMap { $0 })
                    ForEach(snapshot.windows.filter { !excluded.contains($0.id) }) { quota in
                        HStack {
                            Text(quota.name).lineLimit(1)
                            Spacer()
                            Text(QuotaPresentation.usedLabel(quota,
                                                            showRemaining: store.showRemaining))
                                .monospacedDigit()
                        }
                        .font(.system(size: 11))
                    }
                    if snapshot.windows.filter({ !excluded.contains($0.id) }).isEmpty {
                        Text("Nessun'altra quota esposta dal provider.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var claudeConnectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch store.claudeLinkState {
            case .notConfigured, .customStatusLine:
                HStack(spacing: 7) {
                    Image(systemName: "link.badge.plus")
                        .foregroundStyle(Color.accentColor)
                    Text("Claude Code non è ancora collegato.")
                        .font(.system(size: 11, weight: .medium))
                }
                Text(store.claudeLinkState == .customStatusLine ?
                     "La status line attuale sarà mantenuta tramite un bridge locale." :
                     "Configurazione automatica, senza aprire il Terminale.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    store.connectClaude()
                } label: {
                    Label("Collega Claude Code", systemImage: "link")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Configura la status line mantenendo le altre preferenze Claude")
            case .linked, .linkedWithBridge:
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Collegamento attivo")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                if store.fiveHour(.claude) == nil {
                    Text("Le quote arrivano automaticamente dopo una richiesta in Claude Code. LLMPulse non avvia conversazioni AI.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let old = store.snapshots[.claude],
                   !old.isFresh(now: store.now) {
                    let previous = old.windows.first { $0.id == "five_hour" }
                    if let previous {
                        Text("Ultima lettura: \(Int(previous.usedPercent.rounded()))% consumato · \(QuotaStyle.age(old.capturedAt)) · non aggiornata")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            case .missingHelper:
                Text("Ricevitore LLMPulseIngest non disponibile. Reinstalla LLMPulse.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            case .invalidSettings:
                Text("Impostazioni Claude non leggibili o non valide. LLMPulse non le modifica.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            if let error = store.claudeSetupError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { store.inspectClaudeConnection() }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 8) {
                Text("VALORE NELLA MENU BAR")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("Indicatore", selection: $store.showRemaining) {
                    Text("Consumato").tag(false)
                    Text("Rimanente").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Le tre icone mostrano la percentuale delle ultime 5 ore.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("PROVIDER VISIBILI")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(LLMProvider.allCases) { provider in
                    Toggle(provider.title, isOn: Binding(
                        get: { store.isVisible(provider) },
                        set: { store.setVisible(provider, $0) }
                    ))
                    .disabled(store.isVisible(provider) && store.visibleProviders.count == 1)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
            }
            Divider()
            Toggle("Aggiornamento automatico · 5 min", isOn: $store.autoRefresh)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            if !store.antigravityGroups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FAMIGLIA ANTIGRAVITY IN BARRA")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("Gruppo", selection: $store.antigravityGroup) {
                        Text("Automatico · più limitante")
                            .tag(QuotaPresentation.automaticGroup)
                        ForEach(store.antigravityGroups, id: \.self) { group in
                            Text(QuotaStyle.groupName(group)).tag(group)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private final class LLMPulseDelegate: NSObject, NSApplicationDelegate {
    private let popover = NSPopover()
    private let store = LLMPulseStore()
    private var statusItems: [LLMProvider: NSStatusItem] = [:]
    private var gauges: [LLMProvider: QuotaGauge] = [:]
    private var openedProvider: LLMProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // StatusBar inserts new items to the left: create in reverse order.
        for provider in LLMProvider.allCases.reversed() {
            // Fixed 96pt: tighter spacing across the three menu extras, yet
            // enough for the worst case "100% (100)" in monospaced fonts.
            let item = NSStatusBar.system.statusItem(withLength: 96)
            item.isVisible = store.isVisible(provider)
            guard let button = item.button else { continue }
            button.tag = LLMProvider.allCases.firstIndex(of: provider) ?? 0
            button.target = self
            button.action = #selector(toggleProvider(_:))
            button.image = NSImage(systemSymbolName: QuotaStyle.symbol(provider),
                                   accessibilityDescription: provider.title)
            // macOS should resolve the template symbol against the actual
            // menu-bar material/highlight, rather than forcing a brand hue
            // that becomes low-contrast over tinted desktop wallpapers.
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.imagePosition = .imageLeft
            button.alignment = .center
            let gauge = QuotaGauge(frame: NSRect(x: 30, y: 2, width: 58, height: 3))
            gauge.autoresizingMask = [.minYMargin]
            button.addSubview(gauge)
            gauges[provider] = gauge
            statusItems[provider] = item
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 364, height: 420)
        store.didUpdate = { [weak self] in self?.renderStatusItems() }
        renderStatusItems()
        store.start()
    }

    private func renderStatusItems() {
        for provider in LLMProvider.allCases {
            guard let item = statusItems[provider], let button = item.button else { continue }
            let isVisible = store.isVisible(provider)
            if !isVisible, openedProvider == provider {
                popover.close()
                openedProvider = nil
            }
            item.isVisible = isVisible
            let window = store.fiveHour(provider)
            // Weekly must be tied to the SAME Codex/Antigravity quota family
            // as the 5h window. QuotaPresentation already enforces that.
            let weekly = store.weekly(provider)
            let primaryText = QuotaPresentation.usedLabel(window,
                                                           showRemaining: store.showRemaining)
            let weeklyText = QuotaPresentation.weeklyCompactLabel(weekly,
                                                                   showRemaining: store.showRemaining)
            // Never use provider accents or tertiary/secondary label colors
            // for small menu-bar text. The desktop wallpaper and menu-bar
            // material are unpredictable, so readable foreground color must
            // be semantic. Size/weight communicate the weekly hierarchy.
            let foreground = NSColor.labelColor
            let label = NSMutableAttributedString(string: primaryText, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: foreground
            ])
            label.append(NSAttributedString(string: weeklyText, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: foreground
            ]))
            button.attributedTitle = label
            let gauge = gauges[provider]
            gauge?.isAvailable = window != nil
            gauge?.progress = CGFloat((store.showRemaining ?
                window?.remainingPercent : window?.usedPercent) ?? 0) / 100
            gauge?.fillColor = window.map {
                QuotaStyle.statusTint(remaining: $0.remainingPercent, provider: provider)
            } ?? .secondaryLabelColor
            button.toolTip = QuotaPresentation.menuTooltip(
                provider: provider, snapshot: store.snapshots[provider],
                fiveHour: window, weekly: weekly, showRemaining: store.showRemaining,
                error: store.errors[provider])
        }
    }

    @objc private func toggleProvider(_ sender: NSStatusBarButton) {
        let index = sender.tag
        guard LLMProvider.allCases.indices.contains(index) else { return }
        let provider = LLMProvider.allCases[index]
        if popover.isShown {
            let same = openedProvider == provider
            popover.close()
            openedProvider = nil
            if same { return }
        }
        popover.contentViewController = NSHostingController(
            rootView: LLMPulsePopover(store: store, provider: provider,
                                       navigation: LLMPulsePopoverNavigation())
        )
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        openedProvider = provider
    }
}

@main struct LLMPulseMain {
    static func main() {
        if CommandLine.arguments.contains("--claude-ingest") {
            exit(ClaudeIngest.ingest())
        }
        if CommandLine.arguments.contains("--claude-ingest-only") {
            exit(ClaudeIngest.ingest(output: false))
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let delegate = LLMPulseDelegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}
#endif
