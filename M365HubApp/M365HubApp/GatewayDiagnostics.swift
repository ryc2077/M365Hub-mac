import Foundation

// Pure, UI-free helpers for gateway failure diagnosis. Kept free of
// AppKit and of GatewayManager so the logic can be unit-tested with a
// plain swiftc harness (scripts/test-gateway-diagnostics.sh) instead of
// needing the whole app target.
struct PortOccupant: Codable, Equatable {
let name: String
let pid: Int32
// Owner uid, filled by occupant() via ps. nil when ps could not tell
// (caller then treats the occupant as same-user, best effort).
var uid: Int32? = nil
}

// What the failure screen shows, and what is written to
// ~/.config/m365hub/gateway-state.json so CI (and the user, by
// screenshot) can see the same diagnosis the app saw.
struct GatewayFailure: Codable, Equatable {
let title: String
let reason: String
let logTail: String
let occupantName: String?
let occupantPid: Int32?
let occupantUID: Int32?
let createdAt: Date

init(title: String, reason: String, logTail: String,
occupantName: String? = nil, occupantPid: Int32? = nil, occupantUID: Int32? = nil) {
self.title = title
self.reason = reason
self.logTail = logTail
self.occupantName = occupantName
self.occupantPid = occupantPid
self.occupantUID = occupantUID
self.createdAt = Date()
}

var diagnosticText: String {
var parts = ["M365Hub 本地网关故障", title, reason]
if let name = occupantName, let pid = occupantPid {
var line = "占用者：\(name)（pid \(pid)）"
if let uid = occupantUID {
line += "（uid \(uid)）"
}
parts.append(line)
}
if logTail.isEmpty == false {
parts.append("网关日志末尾：\n\(logTail)")
}
return parts.joined(separator: "\n\n")
}

// MARK: - Factories (the copy the failure screen shows)

static func portOccupied(occupant: PortOccupant?, logTail: String) -> GatewayFailure {
if let occ = occupant {
let sameUser = occ.uid == nil || occ.uid == GatewayDiagnostics.currentUID()
if occ.name == "m365hub", sameUser {
// 1.0.29: the occupant IS our gateway and the app already tried a
// normal end (SIGTERM) on it — it did not react. Say so plainly
// instead of the old "only dares to clear its own name" line, which
// was wrong exactly here: the name matched, the signal did not work.
return GatewayFailure(
title: "端口 8230 被占着，网关起不来",
reason: "端口 8230 被「m365hub」（pid \(occ.pid)）占着：它只接受连接、从不回话。"
+ "应用已试过正常结束，它没反应。点「强制清理并重试」会强制结束它并重起网关；"
+ "如果还是不行，请重启电脑。",
logTail: logTail,
occupantName: occ.name, occupantPid: occ.pid, occupantUID: occ.uid)
}
if occ.name == "m365hub" {
// Same name, but another user's process (e.g. root): the app
// cannot end it, so do not offer a force-clean that cannot work.
return GatewayFailure(
title: "端口 8230 被占着，网关起不来",
reason: "端口 8230 被「m365hub」（pid \(occ.pid)）占着：它只接受连接、从不回话。"
+ "该进程属于其他用户，应用无权结束它。请重启电脑后再重新打开应用。",
logTail: logTail,
occupantName: occ.name, occupantPid: occ.pid, occupantUID: occ.uid)
}
var reason = "端口 8230 被「\(occ.name)」（pid \(occ.pid)）占着：它只接受连接、从不回话。"
+ "应用只敢清理自己名字的网关进程，不敢乱杀别的进程，所以没法自己恢复。"
+ "请退出那个进程（或重启电脑），再重新打开应用。"
if let uid = occ.uid, uid != GatewayDiagnostics.currentUID() {
reason += "（该进程属于其他用户。）"
}
return GatewayFailure(
title: "端口 8230 被占着，网关起不来",
reason: reason,
logTail: logTail,
occupantName: occ.name, occupantPid: occ.pid, occupantUID: occ.uid)
}
return GatewayFailure(
title: "端口 8230 被占着，网关起不来",
reason: "端口 8230 被别的进程占着（它只接受连接、从不回话），但查不到是哪个进程。"
+ "请重启电脑后再重新打开应用。",
logTail: logTail)
}

static func noBundledBinary() -> GatewayFailure {
GatewayFailure(
title: "应用包里没有自带网关",
reason: "M365Hub.app 里找不到 Resources/m365hub，自带网关没打进包。"
+ "请重新下载 1.0.29 的完整安装包（不要只拷应用本体）。",
logTail: "")
}

static func spawnFailed(_ error: Error, logTail: String) -> GatewayFailure {
GatewayFailure(
title: "自带网关启动失败",
reason: "启动自带网关时出错：\(error.localizedDescription)",
logTail: logTail)
}

static func exitedEarly(logTail: String) -> GatewayFailure {
GatewayFailure(
title: "自带网关刚启动就退出了",
reason: "自带网关启动后立刻退出了，还没来得及应答。下面是网关日志的末尾，可能是启动时就报错了。",
logTail: logTail)
}

static func noAnswer(logTail: String) -> GatewayFailure {
GatewayFailure(
title: "自带网关 30 秒没有应答",
reason: "自带网关启动了，但 30 秒都没应答。下面是网关日志的末尾。",
logTail: logTail)
}

static func loginStillTimingOut(occupant: PortOccupant?, logTail: String) -> GatewayFailure {
var reason = "登录请求 10 秒无应答，应用已试过清理并重启网关、重登一次，还是超时。"
if let occ = occupant {
reason += "端口 8230 当时被「\(occ.name)」（pid \(occ.pid)）占着。"
}
reason += "下面是网关日志的末尾。"
return GatewayFailure(
title: "登录连续两次超时",
reason: reason,
logTail: logTail,
occupantName: occupant?.name, occupantPid: occupant?.pid, occupantUID: occupant?.uid)
}
}

enum GatewayDiagnostics {
static let port = 8230

// MARK: - lsof parsing (field output: -Fcpn)

// Parse `lsof -nP -iTCP:8230 -sTCP:LISTEN -Fcpn` output. Each
// process block starts with "p<pid>", then "c<command>"; "n<name>"
// lines are the socket address and are ignored. Returns the first
// block that has both a pid and a command, or nil.
static func parseLsofFieldOutput(_ text: String) -> PortOccupant? {
var pid: Int32?
var command: String?
func flush() -> PortOccupant? {
guard let p = pid, let c = command, c.isEmpty == false else { return nil}
return PortOccupant(name: c, pid: p)
}
for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
guard let first = line.first else { continue}
let rest = String(line.dropFirst())
switch first {
case "p":
if let found = flush() { return found}
pid = Int32(rest)
command = nil
case "c":
command = rest
default:
continue
}
}
return flush()
}

// Who listens on 8230 right now, if anyone. Runs /usr/sbin/lsof;
// nil means nothing is listening (or lsof could not run). The
// occupant's uid is filled in via ps so the caller can tell a
// same-user m365hub (which the app may end) from another user's
// process (which it cannot).
static func occupant() -> PortOccupant? {
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fcpn"]
let pipe = Pipe()
p.standardOutput = pipe
p.standardError = FileHandle.nullDevice
do {
try p.run()
} catch {
return nil
}
p.waitUntilExit()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
guard let text = String(data: data, encoding:.utf8), text.isEmpty == false else { return nil}
guard var occ = parseLsofFieldOutput(text) else { return nil }
occ.uid = occupantUID(pid: occ.pid)
return occ
}

// This app's uid, for comparing against an occupant's uid. Via
// /usr/bin/id so the file stays Foundation-only (no raw Darwin call).
// -1 on failure: it never matches a real uid, so a failure here
// fails safe (never kill) instead of guessing.
static func currentUID() -> Int32 {
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/id")
p.arguments = ["-u"]
let pipe = Pipe()
p.standardOutput = pipe
p.standardError = FileHandle.nullDevice
do {
try p.run()
} catch {
return -1
}
p.waitUntilExit()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
guard let text = String(data: data, encoding: .utf8),
let uid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
return -1
}
return uid
}

// Owner uid of a pid, via ps. nil when ps cannot tell (bad pid, or
// ps itself failed) — the caller then treats the occupant as
// same-user, best effort.
static func occupantUID(pid: Int32) -> Int32? {
let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/ps")
p.arguments = ["-o", "uid=", "-p", String(pid)]
let pipe = Pipe()
p.standardOutput = pipe
p.standardError = FileHandle.nullDevice
do {
try p.run()
} catch {
return nil
}
p.waitUntilExit()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
guard let text = String(data: data, encoding:.utf8) else { return nil }
return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

// Kill only a process whose name is exactly `name`. Never anything
// else that happens to hold the port. TERM only — used when the
// occupant is unknown (lsof failed) and there is no pid to escalate
// against; the known-occupant path below is killEscalating.
static func killProcess(named name: String) {
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
p.arguments = ["-x", name]
p.standardOutput = FileHandle.nullDevice
p.standardError = FileHandle.nullDevice
try? p.run()
p.waitUntilExit()
}

// Signal one pid. Used for both steps of the escalation so no
// name-based sweep is ever involved.
static func kill(pid: Int32, signal: Int32 = 15) {
let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/kill")
p.arguments = ["-\(signal)", String(pid)]
p.standardOutput = FileHandle.nullDevice
p.standardError = FileHandle.nullDevice
try? p.run()
p.waitUntilExit()
}

// Escalating kill of a known port occupant (1.0.29). 1.0.28 sent one
// SIGTERM and gave up; a gateway that ignores SIGTERM (e.g. stopped
// in a terminal with Ctrl-Z, or started by another user) survived
// it and the app landed on the failure screen. Now: SIGTERM the pid,
// wait 2s, re-check by pid whether that same pid still holds the
// port; if it does, SIGKILL that pid and wait 1s. Every step is
// reported through `note` so serve-mac.log shows what was tried.
// Returns true when the port ends up free. The caller must already
// have confirmed the occupant is named exactly "m365hub"; this
// function only ever signals the pid it was given, after re-checking
// that pid still holds the port — never a name sweep. An occupant
// owned by another user is never signalled (the app could not end it
// anyway) and returns false.
static func killEscalating(occupant: PortOccupant, note: (String) -> Void) -> Bool {
if let uid = occupant.uid, uid != currentUID() {
note("占用者 \(occupant.name) (pid \(occupant.pid)) 属于其他用户，应用无权结束它")
return false
}
note("正常结束 \(occupant.name) (pid \(occupant.pid))")
kill(pid: occupant.pid)
Thread.sleep(forTimeInterval: 2)
guard let still = GatewayDiagnostics.occupant() else {
note("端口 8230 已空出")
return true
}
if still.pid != occupant.pid {
note("端口 8230 现被 \(still.name) (pid \(still.pid)) 占着，不再是原来的进程，不再清理")
return false
}
note("正常结束没反应，强制结束 pid \(occupant.pid)")
kill(pid: occupant.pid, signal: 9)
Thread.sleep(forTimeInterval: 1)
if GatewayDiagnostics.occupant() == nil {
note("端口 8230 已空出")
return true
}
note("强制结束也没能清掉 pid \(occupant.pid)")
return false
}

// MARK: - Log tail

// Last `maxLines` lines of a log file, reading at most `maxBytes`
// from the end so a huge log cannot blow up the failure screen.
static func logTail(url: URL, maxLines: Int = 40, maxBytes: Int = 16384) -> String {
guard let data = try? Data(contentsOf: url), data.isEmpty == false else { return ""}
let tail = data.suffix(maxBytes)
let text = String(decoding: tail, as: UTF8.self)
let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
return lines.suffix(maxLines).joined(separator: "\n")
}

// Append one "[app]..." line to serve-mac.log, so the occupant the
// app saw is in the same log the failure screen shows.
static func appendNote(_ line: String, to logURL: URL) {
if FileManager.default.fileExists(atPath: logURL.path) == false {
FileManager.default.createFile(atPath: logURL.path, contents: nil)
}
guard let h = try? FileHandle(forWritingTo: logURL) else { return}
defer { try? h.close()}
try? h.seekToEnd()
h.write(Data("[app] \(line)\n".utf8))
}

// MARK: - Failure state file

static func writeState(_ failure: GatewayFailure, to url: URL) {
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted,.sortedKeys]
guard let data = try? enc.encode(failure) else { return}
try? data.write(to: url, options:.atomic)
}

static func readState(from url: URL) -> GatewayFailure? {
guard let data = try? Data(contentsOf: url) else { return nil}
return try? JSONDecoder().decode(GatewayFailure.self, from: data)
}

static func clearState(at url: URL) {
try? FileManager.default.removeItem(at: url)
}
}
