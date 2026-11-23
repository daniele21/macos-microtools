#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import Combine

final class LLMPulseStore: ObservableObject {
    @Published var snapshots: [LLMProvider: QuotaSnapshot] = [:]
    @Published var errors: [LLMProvider: String] = [:]
    @Published var refreshing: Set<LLMProvider> = []
    @Published var autoRefresh: Bool {
        didSet { UserDefaults.standard.set(autoRefresh, forKey: "llmpulse.autoRefresh") }
    }
    var didUpdate: (() -> Void)?
    private var timer: Timer?

    init() {
        autoRefresh = (UserDefaults.standard.object(forKey: "llmpulse.autoRefresh") as? Bool) ?? true
        for provider in LLMProvider.allCases {
            let url = QuotaFiles.directory().appendingPathComponent("\(provider.rawValue).json")
            let file = provider == .claude ? QuotaFiles.claudeFile() : url
            if let cached = QuotaFiles.read(at: file, provider: provider) {
                snapshots[provider] = cached
            }
        }
    }

    func start() {
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self, self.autoRefresh else { return }
            self.refreshAll()
        }
    }

    func refreshAll() {
        for provider in LLMProvider.allCases { refresh(provider) }
    }

    func refresh(_ provider: LLMProvider) {
        guard !refreshing.contains(provider) else { return }
        refreshing.insert(provider)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<QuotaSnapshot, Error>
            do {
                result = .success(try QuotaFetcher.fetch(provider))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing.remove(provider)
                switch result {
                case .success(let snapshot):
                    self.snapshots[provider] = snapshot
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

    var worstRemaining: Double? {
        let values = snapshots.values.filter { $0.isFresh() }.flatMap(\.windows).map(\.remainingPercent)
        return values.min()
    }
}

private enum QuotaStyle {
    static func color(_ remaining: Double) -> Color {
        if remaining <= 10 { return Color(red: 0.92, green: 0.37, blue: 0.36) }
        if remaining <= 25 { return Color(red: 0.94, green: 0.60, blue: 0.24) }
        return Color(red: 0.23, green: 0.69, blue: 0.59)
    }
    static func symbol(_ provider: LLMProvider) -> String {
        switch provider {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "asterisk"
        case .antigravity: return "sparkles"
        }
    }
    static func relative(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "adesso" }
        if seconds < 3600 { return "\(seconds / 60)m fa" }
        if seconds < 86400 { return "\(seconds / 3600)h fa" }
        return "\(seconds / 86400)g fa"
    }
}

private struct QuotaWindowView: View {
    let quota: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(quota.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 6)
                Text("\(Int(quota.remainingPercent.rounded()))%")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(QuotaStyle.color(quota.remainingPercent))
                        .frame(width: max(0, geometry.size.width *
                            CGFloat(quota.remainingPercent / 100)))
                }
            }
            .frame(height: 6)
            HStack {
                Text("Quota rimanente")
                Spacer()
                Text(quota.resetDescription())
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }
}

private struct ProviderCard: View {
    @ObservedObject var store: LLMPulseStore
    let provider: LLMProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: QuotaStyle.symbol(provider))
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(provider.source)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.refreshing.contains(provider) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        store.refresh(provider)
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help("Aggiorna \(provider.title)")
                }
            }
            if let snapshot = store.snapshots[provider] {
                ForEach(snapshot.windows) { window in
                    QuotaWindowView(quota: window)
                    if window.id != snapshot.windows.last?.id {
                        Divider().opacity(0.5)
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: snapshot.isFresh() ? "checkmark.circle.fill" : "clock")
                        .foregroundStyle(snapshot.isFresh() ? Color.green : Color.orange)
                    Text(snapshot.isFresh() ? "Rilevato \(QuotaStyle.relative(snapshot.capturedAt))" :
                            "Dato precedente · \(QuotaStyle.relative(snapshot.capturedAt))")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            } else if !store.refreshing.contains(provider) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                    Text("Nessuna quota disponibile")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            if let error = store.errors[provider] {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

private struct LLMPulsePopover: View {
    @ObservedObject var store: LLMPulseStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 0.23, green: 0.69, blue: 0.59))
                VStack(alignment: .leading, spacing: 2) {
                    Text("LLMPulse")
                        .font(.system(size: 17, weight: .bold))
                    Text("Quote dei tuoi strumenti AI")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refreshAll() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!store.refreshing.isEmpty)
                .help("Aggiorna tutte le quote")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(LLMProvider.allCases) { provider in
                        ProviderCard(store: store, provider: provider)
                    }
                }
                .padding(14)
            }
            Divider()
            HStack(spacing: 12) {
                Toggle("Auto · 5 min", isOn: $store.autoRefresh)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()
                Text("Solo dati locali")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power").font(.system(size: 12))
                }
                .help("Esci da LLMPulse")
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 395, height: 580)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private final class LLMPulseDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let store = LLMPulseStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "waveform.path.ecg",
                                     accessibilityDescription: "LLMPulse - quote AI")
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "LLMPulse · Limiti Codex, Claude e Antigravity"
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 395, height: 580)
        popover.contentViewController = NSHostingController(rootView: LLMPulsePopover(store: store))
        store.didUpdate = { [weak self] in self?.updateStatusColor() }
        store.start()
    }

    private func updateStatusColor() {
        guard let value = store.worstRemaining else {
            statusItem?.button?.contentTintColor = nil
            return
        }
        statusItem?.button?.contentTintColor = value <= 10 ? .systemRed :
            (value <= 25 ? .systemOrange : nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
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
