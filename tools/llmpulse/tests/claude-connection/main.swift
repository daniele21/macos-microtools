import Foundation

func test(_ truth: @autoclosure () -> Bool, _ label: String) {
    if !truth() { fputs("FAILED: \(label)\n", stderr); exit(1) }
}

let fm = FileManager.default
let home = fm.temporaryDirectory.appendingPathComponent("llmpulse-claude-link-" + UUID().uuidString)
let app = home.appendingPathComponent("LLMPulse.app")
let helper = ClaudeStatusLineManager.helperInApp(app)
let settings = home.appendingPathComponent(".claude/settings.json")
defer { try? fm.removeItem(at: home) }

try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
test(ClaudeStatusLineManager.status(home: home, helper: helper) == .missingHelper,
     "missing executable is reported")
test(fm.createFile(atPath: helper.path, contents: Data(), attributes: [.posixPermissions: 0o700]),
     "create fake ingest executable")
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
test(ClaudeStatusLineManager.status(home: home, helper: helper) == .notConfigured,
     "no settings is unconfigured")

let initial = try ClaudeStatusLineManager.connect(home: home, helper: helper)
test(initial == .linked, "one-click integration creates direct statusline")
let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
let direct = (stored["statusLine"] as! [String: Any])["command"] as! String
test(direct.contains(helper.path), "direct helper configured")
let repeatedDirect = try ClaudeStatusLineManager.connect(home: home, helper: helper)
test(repeatedDirect == .linked, "repeated connect is idempotent")
test(ClaudeStatusLineManager.status(home: home, helper: helper) == .linked,
     "linked detected")

let secondHome = fm.temporaryDirectory.appendingPathComponent("llmpulse-claude-custom-" + UUID().uuidString)
let secondHelper = ClaudeStatusLineManager.helperInApp(secondHome.appendingPathComponent("LLMPulse.app"))
let secondSettings = secondHome.appendingPathComponent(".claude/settings.json")
defer { try? fm.removeItem(at: secondHome) }
try fm.createDirectory(at: secondHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
try fm.createDirectory(at: secondSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
test(fm.createFile(atPath: secondHelper.path, contents: Data(), attributes: [.posixPermissions: 0o700]), "second helper")
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: secondHelper.path)
let originalCommand = "jq -r '.model.display_name // \"Claude\"'"
let originalObject: [String: Any] = [
    "permissions": ["allow": ["Read"]],
    "statusLine": ["type": "command", "command": originalCommand, "padding": 2],
    "theme": "dark"
]
let original = String(decoding: try JSONSerialization.data(withJSONObject: originalObject,
    options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
try Data(original.utf8).write(to: secondSettings)
test(ClaudeStatusLineManager.status(home: secondHome, helper: secondHelper) == .customStatusLine,
     "existing custom statusline detected")
let firstBridge = try ClaudeStatusLineManager.connect(home: secondHome, helper: secondHelper)
test(firstBridge == .linkedWithBridge, "custom statusline wrapped rather than discarded")
let bridgedDoc = try JSONSerialization.jsonObject(with: Data(contentsOf: secondSettings)) as! [String: Any]
let bridgedStatus = bridgedDoc["statusLine"] as! [String: Any]
test((bridgedDoc["theme"] as? String) == "dark", "unrelated settings preserved")
test((bridgedStatus["padding"] as? Int) == 2, "statusline padding preserved")
let bridgedCommand = bridgedStatus["command"] as! String
test(bridgedCommand.contains("llmpulse-statusline-bridge-"), "managed bridge configured")
let claudeDir = secondSettings.deletingLastPathComponent()
let files = try fm.contentsOfDirectory(atPath: claudeDir.path)
let scripts = files.filter { $0.hasPrefix("llmpulse-statusline-bridge-") }
let backups = files.filter { $0.hasPrefix("settings.json.llmpulse-backup-") }
test(scripts.count == 1 && backups.count == 1, "bridge script and backup created")
let wrapper = try String(contentsOf: claudeDir.appendingPathComponent(scripts[0]), encoding: .utf8)
test(wrapper.contains(Data(originalCommand.utf8).base64EncodedString()),
     "original command preserved for second invocation")
test(wrapper.contains("LLMPulseIngest"), "bridge invokes quota sink")
let backupData = try String(contentsOf: claudeDir.appendingPathComponent(backups[0]), encoding: .utf8)
test(backupData == original, "original JSON backed up")
let secondBridge = try ClaudeStatusLineManager.connect(home: secondHome, helper: secondHelper)
test(secondBridge == .linkedWithBridge, "bridge setup idempotent")
let sameFiles = try fm.contentsOfDirectory(atPath: claudeDir.path)
test(sameFiles.filter { $0.hasPrefix("llmpulse-statusline-bridge-") }.count == 1,
     "idempotence does not create extra wrappers")

let corruptHome = fm.temporaryDirectory.appendingPathComponent("llmpulse-claude-bad-" + UUID().uuidString)
defer { try? fm.removeItem(at: corruptHome) }
let corruptHelper = ClaudeStatusLineManager.helperInApp(corruptHome.appendingPathComponent("LLMPulse.app"))
let corruptSettings = corruptHome.appendingPathComponent(".claude/settings.json")
try fm.createDirectory(at: corruptHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
try fm.createDirectory(at: corruptSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
test(fm.createFile(atPath: corruptHelper.path, contents: Data(), attributes: [.posixPermissions: 0o700]), "corrupt helper")
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: corruptHelper.path)
try Data("{ invalid JSON }".utf8).write(to: corruptSettings)
test(ClaudeStatusLineManager.status(home: corruptHome, helper: corruptHelper) == .invalidSettings,
     "malformed settings detected")
test((try? ClaudeStatusLineManager.connect(home: corruptHome, helper: corruptHelper)) == nil,
     "invalid config refused")
let corruptData = try String(contentsOf: corruptSettings, encoding: .utf8)
test(corruptData == "{ invalid JSON }", "malformed config not overwritten")
print("LLMPulse Claude connection tests passed")
