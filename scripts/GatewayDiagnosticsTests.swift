import Foundation

// Unit tests for GatewayDiagnostics (the pure helpers the 1.0.28
// self-heal and failure screen rely on). Compiled and run by
// scripts/test-gateway-diagnostics.sh with a plain swiftc harness —
// no Xcode project, no app target. Top-level code is only allowed in
// a file named main.swift, so the tests live in a @main struct.
@main
struct GatewayDiagnosticsTests {
    static func main() {
        var failures = 0

        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            if cond {
                print("PASS: \(name)")
            } else {
                failures += 1
                print("FAIL: \(name) \(detail)")
            }
        }

        // 1. lsof -Fcpn parsing: a hung m365hub holding the port.
        let sample1 = "p4821\ncm365hub\nn127.0.0.1:8230\n"
        check("parse m365hub occupant",
              GatewayDiagnostics.parseLsofFieldOutput(sample1) == PortOccupant(name: "m365hub", pid: 4821))

        // 2. A foreign occupant must parse with its own name, so the app can
        // tell it apart from its own gateway and refuse to kill it.
        let sample2 = "p9102\ncpython3\nn127.0.0.1:8230\n"
        check("parse foreign occupant",
              GatewayDiagnostics.parseLsofFieldOutput(sample2) == PortOccupant(name: "python3", pid: 9102))

        // 3. Empty output means nobody is listening.
        check("parse empty -> nil", GatewayDiagnostics.parseLsofFieldOutput("") == nil)

        // 4. A pid without a command is not an occupant.
        check("parse pid-only -> nil",
              GatewayDiagnostics.parseLsofFieldOutput("p1234\nn127.0.0.1:8230\n") == nil)

        // 5. An incomplete first record is skipped; the first complete one wins.
        let sample5 = "p111\nn127.0.0.1:8230\np2222\ncfoo\nn127.0.0.1:8230\n"
        check("parse skips incomplete record",
              GatewayDiagnostics.parseLsofFieldOutput(sample5) == PortOccupant(name: "foo", pid: 2222))

        // 6. Log tail: last N lines of a 100-line log.
        let tmpDir = FileManager.default.temporaryDirectory
        let logURL = tmpDir.appendingPathComponent("gw-diag-test.log")
        let lines = (1...100).map { "line \($0)" }.joined(separator: "\n")
        try! lines.write(to: logURL, atomically: true, encoding: .utf8)
        let tail = GatewayDiagnostics.logTail(url: logURL, maxLines: 40, maxBytes: 16384)
        let tailLines = tail.split(separator: "\n")
        check("logTail returns last 40 lines",
              tailLines.count == 40 && tailLines.first == "line 61" && tailLines.last == "line 100",
              "got \(tailLines.count) lines, first=\(tailLines.first ?? "?")")

        // 7. Log tail: the byte cap holds on one huge line.
        let bigURL = tmpDir.appendingPathComponent("gw-diag-big.log")
        try! String(repeating: "x", count: 20000).write(to: bigURL, atomically: true, encoding: .utf8)
        let bigTail = GatewayDiagnostics.logTail(url: bigURL, maxLines: 40, maxBytes: 16384)
        check("logTail respects the byte cap", bigTail.count <= 16384, "got \(bigTail.count) chars")

        // 8. Missing log file reads as empty, not a crash.
        check("logTail of missing file is empty",
              GatewayDiagnostics.logTail(url: tmpDir.appendingPathComponent("gw-diag-nope.log")) == "")

        // 9. Failure-state file round-trips, and clear removes it. (Field
        // comparison, not == : the Date in createdAt may lose a fraction of
        // a second through JSON, which is not a product bug.)
        let stateURL = tmpDir.appendingPathComponent("gw-diag-state.json")
        let made = GatewayFailure.portOccupied(
            occupant: PortOccupant(name: "python3", pid: 99), logTail: "tail here")
        GatewayDiagnostics.writeState(made, to: stateURL)
        let back = GatewayDiagnostics.readState(from: stateURL)
        check("state file round-trips",
              back?.title == made.title && back?.reason == made.reason
                && back?.logTail == made.logTail && back?.occupantName == made.occupantName
                && back?.occupantPid == made.occupantPid)
        GatewayDiagnostics.clearState(at: stateURL)
        check("state file cleared", GatewayDiagnostics.readState(from: stateURL) == nil)

        // 10. The failure copy names the occupant (name + pid) — the detail
        // the failure screen exists to show.
        check("portOccupied copy names occupant",
              made.reason.contains("python3") && made.reason.contains("99"))

        // 11. The double-timeout failure says so in its title.
        let timedOut = GatewayFailure.loginStillTimingOut(occupant: nil, logTail: "")
        check("loginStillTimingOut copy", timedOut.title.contains("两次超时"))

        // 12. No occupant: the copy says the occupant could not be found.
        let unknown = GatewayFailure.portOccupied(occupant: nil, logTail: "")
        check("portOccupied without occupant says so", unknown.reason.contains("查不到"))

        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: bigURL)

        if failures == 0 {
            print("DIAGNOSTICS-TEST: PASS")
        } else {
            print("DIAGNOSTICS-TEST: FAIL (\(failures) failures)")
            exit(1)
        }
    }
}
