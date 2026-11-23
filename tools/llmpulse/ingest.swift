import Foundation

// Lightweight Foundation-only executable, invoked by the Claude statusLine
// script. No AppKit/SwiftUI loads on each Claude Code update.
@main struct LLMPulseIngestMain {
    static func main() {
        let silent = CommandLine.arguments.contains("--silent")
        exit(ClaudeIngest.ingest(output: !silent))
    }
}
