import Foundation

func require(_ ok: @autoclosure () -> Bool, _ what: String) {
    if !ok() { fputs("FAIL: \(what)\n", stderr); exit(1) }
}
require(TerminalClipText.clean("\u{1b}[31mERROR\u{1b}[0m") == "ERROR", "ANSI CSI")
require(TerminalClipText.clean("one\r\ntwo") == "one\ntwo", "CRLF")
require(TerminalClipText.tail("one\ntwo\nthree", count: 2) == "two\nthree", "tail")
let data = ["/dev/ttys001", "/Users/test/myproject", "swift test", "1", "2.5", "1790000000", ""]
    .joined(separator: "\u{0}").data(using: .utf8)!
let meta = TerminalClipMetadata(data: data, expectedTTY: "/dev/ttys001")
require(meta != nil, "parse")
require(meta?.exitCode == 1 && meta?.command == "swift test", "fields")
require(TerminalClipMetadata(data: data, expectedTTY: "/dev/ttys002") == nil, "TTY isolation")
require(TerminalClipText.report(meta!, output: "oops").contains("Exit code: 1"), "report")
print("PASS: 7 TerminalClip core checks")
