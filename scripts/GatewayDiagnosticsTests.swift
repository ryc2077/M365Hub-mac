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


        // 13. uid helpers: pid 1 (launchd) belongs to root; a bogus pid
        // has no owner; our own uid matches ps.
        check("occupantUID(pid 1) is root (0)",
              GatewayDiagnostics.occupantUID(pid: 1) == 0)
        check("occupantUID(bogus pid) is nil",
              GatewayDiagnostics.occupantUID(pid: 999999) == nil)
        let ownPid = ProcessInfo.processInfo.processIdentifier
        check("currentUID matches ps for our own pid",
              GatewayDiagnostics.currentUID() == GatewayDiagnostics.occupantUID(pid: ownPid))

        // Live escalation tests (14-15): a python binder holds 8230.
        // They need a free port at start; the diagnostics step runs
        // before anything else binds 8230 in CI.
        func startBinder(trapTERM: Bool) -> Process? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            var code = "import signal, socket, time\n"
            if trapTERM {
                code += "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            }
            code += "s = socket.socket()\n"
            code += "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
            code += "s.bind(('127.0.0.1', 8230))\n"
            code += "s.listen(16)\n"
            code += "time.sleep(60)\n"
            p.arguments = ["-c", code]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
            } catch {
                return nil
            }
            return p
        }

        func waitForOccupant(pid: Int32, seconds: Int) -> PortOccupant? {
            for _ in 0..<seconds {
                if let occ = GatewayDiagnostics.occupant(), occ.pid == pid {
                    return occ
                }
                Thread.sleep(forTimeInterval: 1)
            }
            return nil
        }

        check("port 8230 is free before the live escalation tests",
              GatewayDiagnostics.occupant() == nil)

        // 14. A TERM-ignoring occupant is escalated to SIGKILL: the
        // port comes free and the notes record the forced kill.
        if let binder = startBinder(trapTERM: true) {
            let pid = binder.processIdentifier
            defer {
                if GatewayDiagnostics.occupantUID(pid: pid) != nil {
                    GatewayDiagnostics.kill(pid: pid, signal: 9)
                }
            }
            if let occ = waitForOccupant(pid: pid, seconds: 5) {
                var notes: [String] = []
                let freed = GatewayDiagnostics.killEscalating(occupant: occ, note: { notes.append($0) })
                check("escalation frees a TERM-ignoring occupant", freed)
                check("escalation notes record the forced kill",
                      notes.contains(where: { $0.contains("强制结束") }))
                check("TERM-ignoring process is gone after escalation",
                      GatewayDiagnostics.occupantUID(pid: pid) == nil)
            } else {
                check("TERM-ignoring binder came up on 8230", false, "pid \(pid)")
            }
        } else {
            check("TERM-ignoring binder started", false)
        }

        // 15. A normal occupant dies on SIGTERM alone: the escalation
        // must not jump to SIGKILL.
        if let binder = startBinder(trapTERM: false) {
            let pid = binder.processIdentifier
            defer {
                if GatewayDiagnostics.occupantUID(pid: pid) != nil {
                    GatewayDiagnostics.kill(pid: pid, signal: 9)
                }
            }
            if let occ = waitForOccupant(pid: pid, seconds: 5) {
                var notes: [String] = []
                let freed = GatewayDiagnostics.killEscalating(occupant: occ, note: { notes.append($0) })
                check("escalation frees a normal occupant", freed)
                check("escalation does not force-kill a normal occupant",
                      notes.contains(where: { $0.contains("强制结束") }) == false)
            } else {
                check("normal binder came up on 8230", false, "pid \(pid)")
            }
        } else {
            check("normal binder started", false)
        }

        // 16. A foreign-user occupant is never signalled: killEscalating
        // returns false, notes why, and the process is untouched.
        let foreignUID: Int32 = GatewayDiagnostics.currentUID() == 0 ? 501 : 0
        var foreignNotes: [String] = []
        let foreignFreed = GatewayDiagnostics.killEscalating(
            occupant: PortOccupant(name: "launchd", pid: 1, uid: foreignUID),
            note: { foreignNotes.append($0) })
        check("escalation refuses a foreign-user occupant", foreignFreed == false)
        check("escalation notes say the occupant belongs to another user",
              foreignNotes.contains(where: { $0.contains("其他用户") }))
        check("foreign-user process is untouched (pid 1 still alive)",
              GatewayDiagnostics.occupantUID(pid: 1) != nil)

        // 17. m365hub + same user: the copy says a normal end was
        // tried and it did not react, and points at the force clean.
        let sameUser = GatewayFailure.portOccupied(
            occupant: PortOccupant(name: "m365hub", pid: 74358, uid: GatewayDiagnostics.currentUID()),
            logTail: "")
        check("m365hub same-user copy says a normal end was tried",
              sameUser.reason.contains("已试过正常结束"))
        check("m365hub same-user copy offers the force clean",
              sameUser.reason.contains("强制清理并重试"))

        // 18. m365hub + another user: the copy says the app has no
        // permission and does not offer a force clean.
        let otherUser = GatewayFailure.portOccupied(
            occupant: PortOccupant(name: "m365hub", pid: 74358, uid: foreignUID),
            logTail: "")
        check("m365hub foreign-user copy says no permission",
              otherUser.reason.contains("无权") && otherUser.reason.contains("其他用户"))
        check("m365hub foreign-user copy offers no force clean",
              otherUser.reason.contains("强制清理并重试") == false)

        // 19. A foreign process keeps the old honest wording.
        check("foreign-process copy still refuses to kill others",
              made.reason.contains("不敢乱杀"))

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
