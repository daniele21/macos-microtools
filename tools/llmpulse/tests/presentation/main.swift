import Foundation

func assertQuota(_ good: @autoclosure () -> Bool, _ message: String) {
    if !good() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let now = Date(timeIntervalSince1970: 1_800_000_000)
func window(_ id: String, _ name: String, _ used: Double, _ reset: Int = 1_800_020_000) -> QuotaWindow {
    QuotaWindow(id: id, name: name, usedPercent: used,
                resetsAt: Date(timeIntervalSince1970: Double(reset)))
}
func snap(_ provider: LLMProvider, _ windows: [QuotaWindow], _ age: Int = 0) -> QuotaSnapshot {
    QuotaSnapshot(provider: provider, windows: windows,
                  capturedAt: now.addingTimeInterval(Double(-age)))
}
let codex = snap(.codex, [
    window("codex:primary", "Codex · 5h", 89),
    window("codex:secondary", "Codex · 1 sett.", 72),
    window("other:primary", "Other · 1h", 99),
    window("other:secondary", "Other · 1 sett.", 91)
])
let codexFive = QuotaPresentation.fiveHour(codex, at: now)
assertQuota(codexFive?.id == "codex:primary", "Codex uses only 5h, not 1h")
assertQuota(QuotaPresentation.weekly(codex, matching: codexFive, at: now)?.id == "codex:secondary",
            "Codex weekly is paired with same limitId")
assertQuota(QuotaPresentation.usedLabel(codexFive, showRemaining: false) == "89%", "used %")
assertQuota(QuotaPresentation.usedLabel(codexFive, showRemaining: true) == "11%", "remaining %")
let codexWeekly = QuotaPresentation.weekly(codex, matching: codexFive, at: now)
assertQuota(QuotaPresentation.menuLabels(fiveHour: codexFive, weekly: codexWeekly,
    showRemaining: false, density: .compact).text == "89·72",
    "compact shows both quotas without percentages or parentheses")
assertQuota(QuotaPresentation.menuLabels(fiveHour: codexFive, weekly: codexWeekly,
    showRemaining: true, density: .compact).text == "11·28",
    "compact obeys remaining preference")
assertQuota(QuotaPresentation.menuLabels(fiveHour: codexFive, weekly: nil,
    showRemaining: false, density: .compact).text == "89·—",
    "missing weekly is not zero")
assertQuota(QuotaPresentation.menuLabels(fiveHour: nil, weekly: codexWeekly,
    showRemaining: false, density: .compact).text == "—·72",
    "missing 5h does not hide known weekly")
assertQuota(QuotaPresentation.menuLabels(fiveHour: nil, weekly: nil,
    showRemaining: false, density: .compact).text == "—·—", "no fabricated data")
assertQuota(QuotaPresentation.menuLabels(fiveHour: codexFive, weekly: codexWeekly,
    showRemaining: false, density: .minimal) == QuotaMenuLabels(primary: "89", secondary: nil),
    "minimal omits weekly but keeps correct 5h")
assertQuota(QuotaPresentation.menuLabels(fiveHour: nil, weekly: codexWeekly,
    showRemaining: false, density: .minimal).text == "—",
    "minimal never falls back to weekly")
let full = window("full", "5h", 100)
assertQuota(QuotaPresentation.menuLabels(fiveHour: full, weekly: full,
    showRemaining: false, density: .compact).text == "100·100", "maximum width case")
assertQuota(QuotaMenuDensity.compact.width == 72 && QuotaMenuDensity.minimal.width == 48,
    "stable reduced width for each mode")
assertQuota(QuotaMenuDensity(rawValue: "minimal") == .minimal, "density preference roundtrip")
assertQuota(QuotaPresentation.menuTooltip(provider: .codex, snapshot: codex,
    fiveHour: codexFive, weekly: codexWeekly, showRemaining: false, at: now)
    .contains("7 giorni: 72% consumato"), "tooltip spells out weekly semantics")
let claude = snap(.claude, [
    window("five_hour", "5h", 4),
    window("seven_day", "7 giorni", 0)
])
assertQuota(QuotaPresentation.fiveHour(claude, at: now)?.remainingPercent == 96, "Claude session")
assertQuota(QuotaPresentation.weekly(claude, matching: QuotaPresentation.fiveHour(claude, at: now), at: now)?.remainingPercent == 100, "Claude weekly")
assertQuota(QuotaPresentation.menuLabels(
    fiveHour: QuotaPresentation.fiveHour(claude, at: now),
    weekly: QuotaPresentation.weekly(claude, matching: QuotaPresentation.fiveHour(claude, at: now), at: now),
    showRemaining: false, density: .compact).text == "4·0",
    "true zero weekly used remains visible")
let antigravity = snap(.antigravity, [
    window("gemini-weekly", "Gemini Models · 7 giorni", 1),
    window("gemini-5h", "Gemini Models · Five Hour Limit Remaining", 5),
    window("3p-weekly", "Claude and GPT models · 7 giorni", 50),
    window("3p-5h", "Claude and GPT models · Five Hour Limit Remaining", 9),
    window("argon-weekly", "Gemini 4 Argon · 7 giorni", 0)
])
assertQuota(QuotaPresentation.groups(in: antigravity) == ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon"], "stable group list")
let auto = QuotaPresentation.fiveHour(antigravity, at: now)
assertQuota(auto?.id == "3p-5h", "automatic picks limiting 5h bucket")
assertQuota(QuotaPresentation.weekly(antigravity, matching: auto, at: now)?.id == "3p-weekly", "weekly from matching group")
let selected = QuotaPresentation.fiveHour(antigravity, group: "Gemini Models", at: now)
assertQuota(selected?.id == "gemini-5h", "pin Gemini group")
assertQuota(QuotaPresentation.weekly(antigravity, matching: selected, group: "Gemini Models", at: now)?.id == "gemini-weekly", "weekly follows pinned Gemini group")
assertQuota(QuotaPresentation.fiveHour(antigravity, group: "Gemini 4 Argon", at: now) == nil,
            "weekly-only Argon must never masquerade as 5h")
assertQuota(QuotaPresentation.weekly(antigravity, matching: nil, group: "Gemini 4 Argon", at: now)?.id == "argon-weekly",
            "weekly still available when 5h absent")
assertQuota(QuotaPresentation.fiveHour(antigravity, group: "missing", at: now) == nil,
            "unknown pinned group does not fall back to wrong group")
assertQuota(QuotaPresentation.fiveHour(snap(.codex, [window("weekly", "Codex · 1 sett.", 90)]), at: now) == nil,
            "weekly-only data not shown in menu bar")
assertQuota(QuotaPresentation.fiveHour(snap(.codex, [window("codex:primary", "Codex · 5h", 45, 1_799_999_999)]), at: now) == nil,
            "past-reset windows not shown as live")
assertQuota(QuotaPresentation.fiveHour(snap(.codex, [window("codex:primary", "Codex · 5h", 45)], 3600), at: now) == nil,
            "stale snapshot not shown as live")
assertQuota(QuotaPresentation.usedLabel(nil, showRemaining: false) == "—", "unavailable never 0%")
assertQuota(QuotaPresentation.menuTooltip(provider: .antigravity, snapshot: antigravity,
    fiveHour: auto, showRemaining: false, at: now).contains("Claude and GPT models"),
    "tooltip explains selected Antigravity family")
print("LLMPulse presentation tests passed")
