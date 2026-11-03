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
        var diff = PortPulseDiff()
        expect(diff.newNetworkListeners(results).isEmpty, "first scan establishes baseline")
        expect(diff.newNetworkListeners(results).isEmpty, "steady state does not alert")
        let added = PortListener(pid: 888, command: "python", uid: 501, host: "*", port: 8000)
        expect(diff.newNetworkListeners(results + [added]) == [added], "new nonlocal listener alerts once")
        expect(diff.newNetworkListeners(results + [added]).isEmpty, "no repeated alert")
        expect(diff.newNetworkListeners(results).isEmpty, "removal not an alert")
        expect(diff.newNetworkListeners(results + [added]) == [added], "reopened network listener alerts")
        print("PortPulse parser, scope, safety and diff tests passed.")
    }
}
