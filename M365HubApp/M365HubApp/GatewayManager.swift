import Foundation
import AppKit

// Owns the Go gateway process, mirroring the old Electron shell:
// if a gateway is already listening on 127.0.0.1:8230 it is adopted
// (never killed); otherwise the bundled binary is spawned and only
// that self-spawned process is stopped on quit.
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
        API.session { [weak self] loggedIn in
            if loggedIn {
                // A gateway is already up (or a session exists): adopt it.
                self?.owned = false
                self?.ready = true
                return
            }
            self?.probeThenSpawn()
        }
    }

    private func probeThenSpawn() {
        // Is anything listening at all? A plain GET that fails fast means
        // no gateway; a response (even 401) means one is running.
        var req = URLRequest(url: API.base.appendingPathComponent("/api/admin/session"))
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            DispatchQueue.main.async {
                if resp != nil {
                    self?.owned = false
                    self?.ready = true
                } else {
                    _ = err
                    self?.spawn()
                }
            }
        }.resume()
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
        FileManager.default.createFile(atPath: log.path, contents: nil)
        p.standardOutput = try? FileHandle(forWritingTo: log)
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
