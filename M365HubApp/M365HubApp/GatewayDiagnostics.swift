import Foundation

// Pure, UI-free helpers for gateway failure diagnosis. Kept free of
// AppKit and of GatewayManager so the logic can be unit-tested with a
// plain swiftc harness (scripts/test-gateway-diagnostics.sh) instead of
// needing the whole app target.
struct PortOccupant: Codable, Equatable {
let name: String
let pid: Int32
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
let createdAt: Date

init(title: String, reason: String, logTail: String,
occupantName: String? = nil, occupantPid: Int32? = nil) {
self.title = title
self.reason = reason
self.logTail = logTail
self.occupantName = occupantName
self.occupantPid = occupantPid
self.createdAt = Date()
}

var diagnosticText: String {
var parts = ["M365Hub 本地网关故障", title, reason]
if let name = occupantName, let pid = occupantPid {
parts.append("占用者：\(name)（pid \(pid)）")
}
if logTail.isEmpty == false {
parts.append("网关日志末尾：\n\(logTail)")
}
return parts.joined(separator: "\n\n")
}

// MARK: - Factories (the copy the failure screen shows)

static func portOccupied(occupant: PortOccupant?, logTail: String) -> GatewayFailure {
if let occ = occupant {
return GatewayFailure(
title: "端口 8230 被占着，网关起不来",
reason: "端口 8230 被「\(occ.name)」（pid \(occ.pid)）占着：它只接受连接、从不回话。"
+ "应用只敢清理自己名字的网关进程，不敢乱杀别的进程，所以没法自己恢复。"
+ "请退出那个进程（或重启电脑），再重新打开应用。",
logTail: logTail,
occupantName: occ.name, occupantPid: occ.pid)
}
return GatewayFailure(
title: "端口 8230 被占着，网关起不来",
reason: "端口 8230 被别的进程占着（它只接受连接、从不回话），但查不到是哪个进程。"
+ "应用只敢清理自己名字的网关进程。请重启电脑后再重新打开应用。",
logTail: logTail)
}

static func noBundledBinary() -> GatewayFailure {
GatewayFailure(
title: "应用包里没有自带网关",
reason: "M365Hub.app 里找不到 Resources/m365hub，自带网关没打进包。"
+ "请重新下载 1.0.28 的完整安装包（不要只拷应用本体）。",
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
occupantName: occupant?.name, occupantPid: occupant?.pid)
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
// nil means nothing is listening (or lsof could not run).
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
return parseLsofFieldOutput(text)
}

// Kill only a process whose name is exactly `name`. Never anything
// else that happens to hold the port.
static func killProcess(named name: String) {
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
p.arguments = ["-x", name]
p.standardOutput = FileHandle.nullDevice
p.standardError = FileHandle.nullDevice
try? p.run()
p.waitUntilExit()
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
