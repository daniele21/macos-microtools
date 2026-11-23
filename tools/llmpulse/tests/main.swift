import Foundation

func check(_ ok: @autoclosure () -> Bool, _ message: String) {
    if !ok() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func decoded(_ json: String) -> Data { Data(json.utf8) }

let codex = try QuotaParser.codex(decoded(#"""
{"id":1,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":65,"windowDurationMins":10080,"resetsAt":1800000000}},"other":{"limitId":"other","primary":{"usedPercent":5,"windowDurationMins":60,"resetsAt":1800000001}}}}}
"""#))
check(codex.count == 3, "Codex multi-bucket windows")
check(codex.first(where: { $0.id == "codex:primary" })?.remainingPercent == 75, "Codex 5h remaining")
check(codex.first(where: { $0.id == "codex:secondary" })?.name == "Codex · 1 sett.", "Codex 7d duration")
check(codex.first(where: { $0.id == "other:primary" })?.remainingPercent == 95, "separate Codex buckets")
let single = try QuotaParser.codex(decoded(#"""
{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":100,"windowDurationMins":300}}}}
"""#))
check(single.count == 1 && single[0].status == "critical", "Codex single bucket fallback")
check((try? QuotaParser.codex(decoded(#"{"error":{"code":401}}"#))) == nil, "Codex RPC failure")
check((try? QuotaParser.codex(decoded(#"{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":150}}}}"#))) == nil, "reject invalid percent")

let claude = try QuotaParser.claude(decoded(#"""
{"rate_limits":{"five_hour":{"used_percentage":20.5,"resets_at":1800000000},
"seven_day":{"used_percentage":88,"resets_at":1800100000}}}
"""#))
check(claude.count == 2, "Claude two windows")
check(claude[0].remainingPercent == 79.5, "Claude remaining calculation")
check(claude[1].status == "critical" && claude[1].remainingPercent == 12, "Claude warning classification")
check((try? QuotaParser.claude(decoded(#"{"rate_limits":{}}"#))) == nil, "missing Claude limits not zero")
check((try? QuotaParser.claude(decoded(#"{"rate_limits":{"five_hour":{"used_percentage":true}}}"#))) == nil, "reject boolean as percent")

let agy = try QuotaParser.antigravity(decoded(#"""
{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[
{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.85,"reset_time":"2026-12-01T13:00:00Z"}]},
{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":0.1,"reset_time":"2026-12-03T13:00:00Z"}]}]}}}
"""#))
check(agy.count == 2, "Antigravity two independent model groups")
check(abs(agy[0].remainingPercent - 85) < 0.001, "remaining_fraction not mistaken for used")
check(abs(agy[1].usedPercent - 90) < 0.001, "Antigravity used conversion")
check(agy[0].resetsAt != agy[1].resetsAt, "independent Antigravity reset")
check((try? QuotaParser.antigravity(decoded(#"{"status":"ERROR"}"#))) == nil, "Antigravity failed response")
check((try? QuotaParser.antigravity(decoded(#"""
{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"buckets":[{"remaining_fraction":2.0}]}]}}}
"""#))) == nil, "reject impossible fraction")

let now = Date(timeIntervalSince1970: 1000)
let snapshot = QuotaSnapshot(provider: .claude, windows: claude, capturedAt: now)
check(snapshot.isFresh(now: Date(timeIntervalSince1970: 1500)), "snapshot fresh")
check(!snapshot.isFresh(now: Date(timeIntervalSince1970: 2000)), "snapshot stale")
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("llmpulse-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: temp) }
let file = temp.appendingPathComponent("nested/claude-quota.json")
try QuotaFiles.write(snapshot, at: file)
check(QuotaFiles.read(at: file, provider: .claude)?.windows.count == 2, "private cache roundtrip")
check(QuotaFiles.read(at: file, provider: .codex) == nil, "cache provider isolation")
print("LLMPulse core tests passed")
