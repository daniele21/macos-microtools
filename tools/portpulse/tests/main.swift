import Foundation

@main
struct PortPulseTests {
    static func main() {
        func expect(_ predicate: @autoclosure () -> Bool, _ message: String) {
            if !predicate() {
                fputs("FAIL: \(message)\n", stderr)
                exit(1)
            }
        }

        let fixture = """
        p123
        cnode dev server
        u501
        f9
        n127.0.0.1:3000
        f10
        n[::1]:3000
        p456
        cllama-server
        u501
        f4
        n*:1235
        f5
        n0.0.0.0:1235
        p789
        cpostgres
        u0
        f7
        n[::]:5432
        p456
        cllama-server
        u501
        f4
        n*:1235
        """
        let results = PortPulseCore.parse(fixture)
        expect(results.count == 5, "deduplicated listeners; one row per bound endpoint")
        expect(results.map(\.port) == [1235, 1235, 3000, 3000, 5432], "numeric port ordering")
        expect(results.first { $0.host == "::1" }?.scope == .local, "IPv6 loopback")
        expect(results.first { $0.host == "127.0.0.1" }?.scope == .local, "IPv4 loopback")
        expect(results.first { $0.host == "*" }?.scope == .network, "wildcard binding is nonlocal")
        expect(results.first { $0.host == "0.0.0.0" }?.scope == .network, "all interfaces is nonlocal")
        expect(results.first { $0.host == "::" }?.scope == .network, "IPv6 all interfaces is nonlocal")
        expect(PortPulseCore.parseEndpoint("bad") == nil, "invalid endpoint rejected")
        expect(PortPulseCore.parseEndpoint("127.0.0.1:0") == nil, "zero port rejected")
        expect(PortPulseCore.parseEndpoint("127.0.0.1:70000") == nil, "out-of-range port rejected")
        expect(PortPulseCore.parseEndpoint("127.0.0.1:80->other") == nil, "nonlistener rejected")
        expect(PortPulseCore.parseEndpoint("[fe80::1]:8080")?.host == "fe80::1", "IPv6 host")
        let own = results.first { $0.pid == 123 }!
        let root = results.first { $0.pid == 789 }!
        expect(PortPulseCore.canTerminate(own, currentUID: 501, ownPID: 999), "owned process may stop")
        expect(!PortPulseCore.canTerminate(own, currentUID: 501, ownPID: 123), "cannot stop app itself")
        expect(!PortPulseCore.canTerminate(root, currentUID: 501, ownPID: 999), "cannot stop another user")
        let unknown = PortListener(pid: 32, command: "unknown", uid: nil, host: "*", port: 8888)
        expect(!PortPulseCore.canTerminate(unknown, currentUID: 501, ownPID: 999), "unknown owner cannot stop")
        let summary = PortPulseSummary(results)
        expect(summary.total == 3, "port total deduplicates multiple addresses")
        expect(summary.network == 2, "network count deduplicates dual-stack wildcard binds")
        expect(summary.local == 1, "network scope takes precedence on shared port")
        expect(summary.total == summary.local + summary.network, "summary segments sum to total")
        expect(PortPulseCore.matches(own, filter: 0, search: "123"), "search matches PID")
        expect(PortPulseCore.matches(own, filter: 1, search: "node"), "local filtered search")
        expect(!PortPulseCore.matches(own, filter: 2, search: "node"), "network filter excludes loopback")
        expect(PortPulseCore.matches(root, filter: 2, search: "::"), "network matches IPv6 host")
        // The real node process title on macOS is "next-server (v16.4.2)";
        // lsof alone reports only "node".
        expect(PortPulseOriginCore.serviceName(lsofName: "node",
                                               psCommand: "next-server (v16.4.2)") == "Next.js",
               "recognize Next.js from actual process title")
        expect(PortPulseOriginCore.serviceName(lsofName: "node",
                                               psCommand: nil) == "node",
               "do not guess services without evidence")
        expect(PortPulseOriginCore.serviceName(lsofName: "postgres",
                                               psCommand: "postgres -D data") == "postgres",
               "preserve known process label")
        expect(PortPulseOriginCore.elapsedLabel("10:31:34") == "10h 31m",
               "hours and minutes")
        expect(PortPulseOriginCore.elapsedLabel("00:40") == "40s",
               "short runtime")
        expect(PortPulseOriginCore.elapsedLabel("2-05:12:01") == "2g 5h",
               "multi-day duration")
        expect(PortPulseOriginCore.elapsedLabel("bad") == nil,
               "malformed etime safely omitted")
        let fields = PortPulseOriginCore.psFields("   10:31:34 next-server (v16.4.2) \n")
        expect(fields.elapsed == "10:31:34" &&
               fields.command == "next-server (v16.4.2)",
               "parse ps elapsed and command as two fields")
        expect(PortPulseOriginCore.cwdFromLsof("""
        p24227
        fcwd
        n/Users/daniele/Projects/sdg-chat-activity-diagnostic-live/ui
        """) == "/Users/daniele/Projects/sdg-chat-activity-diagnostic-live/ui",
               "read cwd field rather than unrelated lsof text")
        let cwd = "/Users/daniele/Projects/sdg-chat-activity-diagnostic-live/ui"
        let projectRoot = "/Users/daniele/Projects/sdg-chat-activity-diagnostic-live"
        let repo = PortPulseOriginCore.projectLocation(cwd: cwd, isRepository: { $0 == projectRoot })
        expect(repo?.name == "sdg-chat-activity-diagnostic-live" && repo?.path == projectRoot,
               "prefer real Git root above ui subdirectory")
        let fallback = PortPulseOriginCore.projectLocation(cwd: cwd, isRepository: { _ in false })
        expect(fallback?.name == "sdg-chat-activity-diagnostic-live",
               "recognize development directory without .git")
        expect(PortPulseOriginCore.projectLocation(cwd: "/System/Library/PrivateFrameworks",
                                                   isRepository: { _ in false }) == nil,
               "do not mislabel system processes as user projects")
        expect(PortPulseOriginCore.projectLocation(cwd: nil,
                                                   isRepository: { _ in false }) == nil,
               "unavailable origins remain unavailable")

        var diff = PortPulseDiff()
        expect(diff.newNetworkListeners(results).isEmpty, "first scan establishes baseline")
        expect(diff.newNetworkListeners(results).isEmpty, "steady state does not alert")
        let added = PortListener(pid: 888, command: "python", uid: 501, host: "*", port: 8000)
        expect(diff.newNetworkListeners(results + [added]) == [added], "new nonlocal listener alerts once")
        expect(diff.newNetworkListeners(results + [added]).isEmpty, "no repeated alert")
        expect(diff.newNetworkListeners(results).isEmpty, "removal not an alert")
        expect(diff.newNetworkListeners(results + [added]) == [added], "reopened network listener alerts")
        print("PortPulse parser, process-origin, project paths, scope, safety and diff tests passed.")
    }
}
