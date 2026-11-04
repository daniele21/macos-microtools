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


        // Five llama-server listeners should become one compact group, with
        // a unique PID for each model server.
        let llama = (0..<5).map { i in
            PortListener(pid: Int32(40000 + i), command: "llama-server", uid: 501,
                         host: "127.0.0.1", port: 8091 + i)
        }
        let groups = PortPulseGrouping.groups(llama)
        expect(groups.count == 1, "five llama servers grouped by exact service name")
        let group = groups[0]
        expect(group.ports == [8091, 8092, 8093, 8094, 8095],
               "group contains all five listening ports in order")
        expect(group.pids.count == 5, "process count deduplicates PID")
        expect(!group.isNetwork, "loopback-only group is local")
        expect(PortPulseGrouping.canStop(group, currentUID: 501, ownPID: 999),
               "entire owned service group may be stopped after confirmation")
        expect(PortPulseGrouping.validateStop(group, against: group, currentUID: 501, ownPID: 999),
               "fresh matching group is valid")
        expect(!PortPulseGrouping.validateStop(group, against: nil, currentUID: 501, ownPID: 999),
               "vanished group aborts before any signals")
        let changed = PortPulseGrouping.groups(Array(llama.dropLast()))[0]
        expect(!PortPulseGrouping.validateStop(group, against: changed, currentUID: 501, ownPID: 999),
               "missing listener prevents partial group termination")
        let late = PortListener(pid: 50000, command: "llama-server", uid: 501,
                                host: "127.0.0.1", port: 8096)
        let expanded = PortPulseGrouping.groups(llama + [late])[0]
        expect(!PortPulseGrouping.validateStop(group, against: expanded,
                                               currentUID: 501, ownPID: 999),
               "new listener must not silently join a confirmed group")
        let otherOwner = PortListener(pid: 50001, command: "llama-server", uid: 0,
                                      host: "127.0.0.1", port: 8097)
        let mixed = PortPulseGrouping.groups(llama + [otherOwner])[0]
        expect(!PortPulseGrouping.canStop(mixed, currentUID: 501, ownPID: 999),
               "cross-UID group cannot be bulk stopped")
        expect(!PortPulseGrouping.validateStop(group, against: mixed,
                                               currentUID: 501, ownPID: 999),
               "foreign UID fails entire atomic preflight")
        let protected = PortPulseGrouping.groups([
            PortListener(pid: 714, command: "ControlCenter", uid: 501, host: "*", port: 5000),
            PortListener(pid: 714, command: "ControlCenter", uid: 501, host: "*", port: 7000)
        ])[0]
        expect(!PortPulseGrouping.canStop(protected, currentUID: 501, ownPID: 999),
               "macOS ControlCenter group is protected")
        let nodes = [
            PortListener(pid: 51, command: "node", uid: 501, host: "::1", port: 4000),
            PortListener(pid: 52, command: "node", uid: 501, host: "::1", port: 4321)
        ]
        expect(PortPulseGrouping.groups(nodes).count == 2,
               "generic node runtimes must not group across unrelated projects")
        let sameNode = [
            PortListener(pid: 51, command: "node", uid: 501, host: "::1", port: 4000),
            PortListener(pid: 51, command: "node", uid: 501, host: "::1", port: 4001)
        ]
        expect(PortPulseGrouping.groups(sameNode).count == 1,
               "one runtime PID can group its own multiple ports")
        let duplicateSocket = PortListener(pid: 40000, command: "llama-server", uid: 501,
                                           host: "::1", port: 8091)
        let dualGroup = PortPulseGrouping.groups(llama + [duplicateSocket])[0]
        expect(dualGroup.ports.count == 5 && dualGroup.pids.count == 5,
               "IPv4 + IPv6 socket rows do not inflate group port or PID counts")
        let filteredPort = llama.filter {
            PortPulseCore.matches($0, filter: 0, search: "8092")
        }
        expect(PortPulseGrouping.groups(filteredPort).first?.ports == [8092],
               "search narrows group membership rather than hiding matched port")
        expect(!PortPulseGrouping.canStop(PortPulseGrouping.groups(filteredPort)[0],
                                          currentUID: 501, ownPID: 999),
               "single matched port cannot trigger bulk termination")
        let mixedScope = PortPulseGrouping.groups(llama + [
            PortListener(pid: 50000, command: "llama-server", uid: 501, host: "*", port: 8096)
        ])[0]
        expect(mixedScope.isNetwork, "network warning takes precedence for group")

        var diff = PortPulseDiff()
        expect(diff.newNetworkListeners(results).isEmpty, "first scan establishes baseline")
        expect(diff.newNetworkListeners(results).isEmpty, "steady state does not alert")
        let added = PortListener(pid: 888, command: "python", uid: 501, host: "*", port: 8000)
        expect(diff.newNetworkListeners(results + [added]) == [added], "new nonlocal listener alerts once")
        expect(diff.newNetworkListeners(results + [added]).isEmpty, "no repeated alert")
        expect(diff.newNetworkListeners(results).isEmpty, "removal not an alert")
        expect(diff.newNetworkListeners(results + [added]) == [added], "reopened network listener alerts")
        print("PortPulse grouping, bulk-stop preflight, parser, origin, scope, safety and diff tests passed.")
    }
}
