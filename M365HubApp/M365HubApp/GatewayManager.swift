import Foundation
import AppKit

// Owns the Go gateway process, mirroring the old Electron shell:
// a healthy gateway already listening on 127.0.0.1:8230 is adopted;
// a hung one (accepts TCP but never answers) whose process is named
// exactly "m365hub" is cleared so the bundled binary can start;
// otherwise the bundled binary is spawned and only that self-spawned
// process is stopped on quit.
//
// 1.0.28: `ready` is no longer set on failure paths. A dead gateway
// used to land the user on a login screen that could never log in
// ("The request timed out."). Now a failed start enters `failure`
// instead, and the app shows a failure screen with the real cause,
// the log tail, and a retry button. A login that times out heals the
// same way (see healAfterLoginTimeout): the hung occupant is cleared
// only if it is named exactly "m365hub", the bundled gateway is
// restarted, and the login is retried once automatically.
//
// 1.0.29: the kill escalates. 1.0.28 sent one SIGTERM and gave up; a
// gateway that ignores SIGTERM (e.g. stopped in a terminal) survived
// it, and the failure screen named a m365hub occupant the app had
// supposedly cleared. Both cleanup points now run killEscalating
// (SIGTERM, wait 2s, SIGKILL by pid if the same pid still holds the
// port, every step logged). The occupant's uid is recorded, so a
// foreign-user process gets an honest "no permission" copy instead
// of the misleading "only dares to clear its own name" line. The
// failure screen also offers forceCleanAndRetry: one tap re-runs the
// escalation against a confirmed same-user m365hub occupant.
final class GatewayManager: ObservableObject {
    static let shared = GatewayManager()

    @Published var ready = false
    @Published var failure: GatewayFailure?
    @Published var recovering = false
    private var process: Process?
    private(set) var owned = false

    enum HealOutcome {
        case loggedIn(mustChange: Bool)
        case failed(String)
    }

    private var dataDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/m365hub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var logFileURL: URL { dataDir.appendingPathComponent("serve-mac.log") }
    private var stateFileURL: URL { dataDir.appendingPathComponent("gateway-state.json") }

    func start() {
        // A retry starts clean: drop the old failure (and its state
        // file) so a healed launch does not keep showing the old
        // failure screen.
        failure = nil
        ready = false
        recovering = false
        GatewayDiagnostics.clearState(at: stateFileURL)
        // Probe with a short timeout first. API.session defaults to a
        // 120s timeout, so a gateway that accepts the connection but
        // never answers (hung old gateway) left the app on the
        // "正在启动本地网关…" spinner for minutes. A raw 2s probe
        // distinguishes "nothing there" from "something hung" fast.
        probe { [weak self] outcome in
            switch outcome {
            case .answering:
                // Something answers: adopt it, then confirm login state.
                API.session(timeout: 5) { _ in
                    self?.owned = false
                    self?.ready = true
                }
            case .nothing:
                self?.spawn()
            case .hung:
                self?.clearHungGateway()
            }
        }
    }

    private enum ProbeOutcome { case answering, nothing, hung }

    // One 2s probe of /api/admin/session. A response (even 401) means a
    // live gateway; a fast failure means nothing is listening; a timeout
    // means something accepted the TCP connection but never answers —
    // a hung gateway holding 8230.
    private func probe(completion: @escaping (ProbeOutcome) -> Void) {
        var req = URLRequest(url: API.base.appendingPathComponent("/api/admin/session"))
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { _, resp, err in
            DispatchQueue.main.async {
                if resp != nil {
                    completion(.answering)
                } else if let urlErr = err as? URLError, urlErr.code == .timedOut {
                    completion(.hung)
                } else {
                    completion(.nothing)
                }
            }
        }.resume()
    }

    private func currentLogTail() -> String {
        GatewayDiagnostics.logTail(url: logFileURL)
    }

    private func appendNote(_ line: String) {
        GatewayDiagnostics.appendNote(line, to: logFileURL)
    }

    // Enter the failure state: the app shows the failure screen
    // instead of the login screen, and the diagnosis is written to
    // gateway-state.json so it survives the app and CI can read it.
    // Always called on the main queue (it publishes).
    private func enterFailure(_ value: GatewayFailure) {
        failure = value
        recovering = false
        GatewayDiagnostics.writeState(value, to: stateFileURL)
        appendNote("网关失败：\(value.title) — \(value.reason)")
    }

    // The hung gateway owns 8230, so a fresh one cannot start. Only kill
    // a process whose name is exactly "m365hub" — never anything else
    // that happens to hold the port. Re-probe afterwards: if the port is
    // free, spawn our own gateway; if it still hangs, something else
    // owns the port, so enter the failure state (with the occupant's
    // name and pid) instead of killing blindly or showing a dead login
    // screen.
    private func clearHungGateway() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let occupant = GatewayDiagnostics.occupant()
            if let occ = occupant {
                self.appendNote("启动探测：8230 占用者 \(occ.name) (pid \(occ.pid))")
                if occ.name == "m365hub" {
                    // 1.0.29: escalating kill (TERM, then SIGKILL by pid
                    // if the same pid still holds the port). A
                    // TERM-ignoring gateway survived 1.0.28's single
                    // SIGTERM, which is exactly the failure the user hit.
                    _ = GatewayDiagnostics.killEscalating(occupant: occ, note: { self.appendNote($0) })
                }
            } else {
                // Occupant unknown (lsof failed): fall back to the old
                // TERM-by-name, which only ever touches m365hub
                // processes. There is no pid to escalate against.
                GatewayDiagnostics.killProcess(named: "m365hub")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.probe { outcome in
                    switch outcome {
                    case .answering:
                        API.session(timeout: 5) { _ in
                            self.owned = false
                            self.ready = true
                        }
                    case .nothing:
                        self.spawn()
                    case .hung:
                        let stillThere = GatewayDiagnostics.occupant()
                        self.enterFailure(.portOccupied(occupant: stillThere, logTail: self.currentLogTail()))
                    }
                }
            }
        }
    }

    // Called when a login request timed out: the gateway on 8230
    // accepts TCP but never answers HTTP. Heal it the same way startup
    // does — identify the occupant (logged), kill it only if it is
    // named exactly "m365hub", restart the bundled gateway, and retry
    // the login once automatically. Retrying a second time would just
    // burn another 10s on the same dead gateway, so a second timeout
    // enters the failure state instead.
    func healAfterLoginTimeout(password: String, completion: @escaping (HealOutcome) -> Void) {
        recovering = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let occupant = GatewayDiagnostics.occupant()
            let occDesc = occupant.map { "\($0.name) (pid \($0.pid))" } ?? "查不到占用者"
            self.appendNote("登录超时，8230 占用者：\(occDesc)")
            if let occ = occupant, occ.name != "m365hub" {
                // A foreign process holds the port: we cannot heal it
                // and must not kill it.
                let value = GatewayFailure.portOccupied(occupant: occ, logTail: self.currentLogTail())
                DispatchQueue.main.async {
                    self.enterFailure(value)
                    completion(.failed(value.reason))
                }
                return
            }
            if let occ = occupant {
                // 1.0.29: escalating kill (TERM, then SIGKILL by pid if
                // the same pid still holds the port). A foreign-user
                // occupant is never signalled; killEscalating returns
                // false and logs why.
                _ = GatewayDiagnostics.killEscalating(occupant: occ, note: { self.appendNote($0) })
            }
            DispatchQueue.main.async {
                self.probe { outcome in
                    switch outcome {
                    case .answering:
                        self.retryLogin(password: password, occupant: occupant, completion: completion)
                    case .nothing:
                        self.spawn { ok in
                            if ok {
                                self.retryLogin(password: password, occupant: occupant, completion: completion)
                            } else {
                                // spawn() already entered the failure state.
                                completion(.failed(self.failure?.reason ?? "网关启动失败"))
                            }
                        }
                    case .hung:
                        let stillThere = GatewayDiagnostics.occupant()
                        let value = GatewayFailure.portOccupied(occupant: stillThere, logTail: self.currentLogTail())
                        self.enterFailure(value)
                        completion(.failed(value.reason))
                    }
                }
            }
        }
    }

    // 1.0.29: the failure screen's "强制清理并重试" button. Re-runs
    // the escalation against the occupant the failure screen named,
    // but only after re-confirming (via lsof) that the same pid with
    // the name m365hub still holds the port — never a stale pid, never
    // a foreign process. If the port comes free, restart normally
    // (start() re-probes and spawns); if not, back to the failure
    // screen with the fresh reason.
    func forceCleanAndRetry() {
        guard let f = failure, let name = f.occupantName, name == "m365hub",
              let pid = f.occupantPid else { return }
        failure = nil
        recovering = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let current = GatewayDiagnostics.occupant()
            guard let occ = current, occ.pid == pid, occ.name == "m365hub" else {
                // Occupant changed or the port freed on its own: just
                // restart normally instead of killing a stale pid.
                self.appendNote("强制清理：8230 占用者已变或端口已空出，直接重起")
                DispatchQueue.main.async { self.start() }
                return
            }
            self.appendNote("强制清理：8230 占用者 \(occ.name) (pid \(occ.pid))")
            let freed = GatewayDiagnostics.killEscalating(occupant: occ, note: { self.appendNote($0) })
            DispatchQueue.main.async {
                if freed {
                    self.start()
                } else {
                    let still = GatewayDiagnostics.occupant()
                    self.enterFailure(.portOccupied(occupant: still, logTail: self.currentLogTail()))
                }
            }
        }
    }

    // The single automatic re-login after a heal. On success the
    // caller logs the user in; on a second timeout the failure state
    // is entered (the gateway is still dead); any other error (e.g.
    // wrong password) is reported as-is without entering failure.
    private func retryLogin(password: String, occupant: PortOccupant?,
                            completion: @escaping (HealOutcome) -> Void) {
        API.login(password: password) { [weak self] r in
            guard let self else { return }
            self.recovering = false
            switch r {
            case .success(let mc):
                completion(.loggedIn(mustChange: mc))
            case .failure(let e):
                if (e as? URLError)?.code == .timedOut {
                    let value = GatewayFailure.loginStillTimingOut(occupant: occupant, logTail: self.currentLogTail())
                    self.enterFailure(value)
                    completion(.failed(value.reason))
                } else {
                    completion(.failed(e.localizedDescription))
                }
            }
        }
    }

    private func spawn(completion: ((Bool) -> Void)? = nil) {
        guard let bin = Bundle.main.path(forResource: "m365hub", ofType: nil) else {
            // No bundled binary (e.g. first Xcode run before the
            // Resources binary is in place): fail loudly instead of
            // showing a login screen that can never work.
            enterFailure(.noBundledBinary())
            completion?(false)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["M365_DATA_DIR"] = dataDir.path
        env["M365_LISTEN"] = "127.0.0.1:8230"
        p.environment = env
        let log = logFileURL
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        // Seek to the end so a restart appends to serve-mac.log instead
        // of overwriting it from byte 0: the previous launch's log is
        // exactly the evidence needed when a restart fails.
        let logHandle = try? FileHandle(forWritingTo: log)
        try? logHandle?.seekToEnd()
        p.standardOutput = logHandle
        p.standardError = p.standardOutput
        do {
            try p.run()
            process = p
            owned = true
        } catch {
            enterFailure(.spawnFailed(error, logTail: currentLogTail()))
            completion?(false)
            return
        }
        // Poll until the gateway answers.
        poll(attempt: 0, completion: completion)
    }

    private func poll(attempt: Int, completion: ((Bool) -> Void)? = nil) {
        // If our spawned gateway already exited, polling for 30s is
        // pointless: enter the failure state (with the log tail)
        // immediately instead of another half-minute spinner followed
        // by a dead login screen.
        if let p = process, !p.isRunning {
            enterFailure(.exitedEarly(logTail: currentLogTail()))
            completion?(false)
            return
        }
        // A raw probe: only an actual HTTP response means the gateway is
        // up (API.session cannot tell "down" from "not logged in").
        var req = URLRequest(url: API.base.appendingPathComponent("/api/admin/session"))
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            DispatchQueue.main.async {
                if resp != nil {
                    self?.ready = true
                    completion?(true)
                } else if attempt < 30 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.poll(attempt: attempt + 1, completion: completion)
                    }
                } else {
                    self?.enterFailure(.noAnswer(logTail: self?.currentLogTail() ?? ""))
                    completion?(false)
                }
            }
        }.resume()
    }

    func stopIfOwned() {
        if owned { process?.terminate() }
    }
}
