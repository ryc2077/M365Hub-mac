import Foundation
import AppKit

// Owns the Go gateway process, mirroring the old Electron shell:
// a healthy gateway already listening on 127.0.0.1:8230 is adopted;
// a hung one (accepts TCP but never answers) whose process is named
// exactly "m365hub" is cleared so the bundled binary can start;
// otherwise the bundled binary is spawned and only that self-spawned
// process is stopped on quit.
final class GatewayManager: ObservableObject {
    static let shared = GatewayManager()

    @Published var ready = false
    private var process: Process?
    private(set) var owned = false

    private var dataDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/m365hub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func start() {
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

    // The hung gateway owns 8230, so a fresh one cannot start. Only kill
    // a process whose name is exactly "m365hub" — never anything else
    // that happens to hold the port. Re-probe afterwards: if the port is
    // free, spawn our own gateway; if it still hangs, something else
    // owns the port, so surface the login screen (and its real error)
    // instead of killing blindly.
    private func clearHungGateway() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let killer = Process()
            killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killer.arguments = ["-x", "m365hub"]
            try? killer.run()
            killer.waitUntilExit()
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
                        self.ready = true
                    }
                }
            }
        }
    }

    private func spawn() {
        guard let bin = Bundle.main.path(forResource: "m365hub", ofType: nil) else {
            // No bundled binary (e.g. first Xcode run before build-gateway.sh):
            // mark ready anyway so the login screen can show the real error
            // from the API instead of hanging on a spinner.
            ready = true
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["M365_DATA_DIR"] = dataDir.path
        env["M365_LISTEN"] = "127.0.0.1:8230"
        p.environment = env
        let log = dataDir.appendingPathComponent("serve-mac.log")
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
            ready = true
            return
        }
        // Poll until the gateway answers.
        poll(attempt: 0)
    }

    private func poll(attempt: Int) {
        // If our spawned gateway already exited, polling for 30s is
        // pointless: surface the login screen (and its real error)
        // immediately instead of another half-minute spinner.
        if let p = process, !p.isRunning {
            ready = true
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
                } else if attempt < 30 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.poll(attempt: attempt + 1)
                    }
                } else {
                    self?.ready = true
                }
            }
        }.resume()
    }

    func stopIfOwned() {
        if owned { process?.terminate() }
    }
}
