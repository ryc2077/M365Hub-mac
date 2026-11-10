import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Native admin screens. Each one is a plain SwiftUI view filled from
// the gateway console API — no web content anywhere in the app.

struct Row: View {
    var text: String
    var body: some View {
        Text(text).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionPage<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.largeTitle)
                if let s = subtitle { Text(s).foregroundStyle(.secondary) }
                content()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DashboardView: View {
    @State private var lines: [String] = []
    @State private var error = ""
    var body: some View {
        SectionPage(title: "仪表盘", subtitle: "账号池、代理池与上游配额的实时状态") {
            ForEach(lines, id: \.self) { Row(text: $0) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .onAppear {
            API.request("/api/stats") { r in
                guard case .success(let st) = r else { return }
                let pool = st["pool"] as? [String: Any]
                var ls: [String] = []
                ls.append("账号：\(st["accounts"] as? Int ?? 0)（活跃 \(pool?["active"] as? Int ?? 0) · 冷却 \(pool?["disabled"] as? Int ?? 0)）")
                ls.append("在途请求：\(pool?["inFlight"] as? Int ?? 0) · 熔断：\((pool?["circuitOpen"] as? Bool ?? false) ? "已打开" : "关闭")")
                ls.append("监听地址：\(st["listen"] as? String ?? "—")")
                ls.append("API Key：\(st["keys"] as? Int ?? 0) 个 · 代理：\(st["proxies"] as? Int ?? 0) 个")
                lines = ls
                API.request("/api/quota") { r2 in
                    if case .success(let q) = r2, q["available"] as? Bool == true {
                        lines.append("最佳剩余消息数：\(q["bestHeadroom"] as? Int ?? -1)")
                        if q["allExhausted"] as? Bool == true { lines.append("全部账号会话额度已耗尽") }
                    } else {
                        lines.append("尚无配额数据，先发一次聊天请求")
                    }
                }
            }
        }
    }
}

struct AccountsView: View {
    @State private var accounts: [[String: Any]] = []
    @State private var error = ""
    @State private var notice = ""
    @State private var callbackURL = ""
    @State private var authURL = ""

    var body: some View {
        SectionPage(title: "账号", subtitle: "多账号轮询、并发上限与故障自动转移") {
            Button("添加账号（PKCE 浏览器授权）") {
                API.request("/api/auth/start", method: "POST", body: ["flow": "pkce"]) { r in
                    if case .success(let d) = r {
                        authURL = d["authUrl"] as? String ?? ""
                        if let url = URL(string: authURL) { NSWorkspace.shared.open(url) }
                    } else if case .failure(let e) = r { error = e.localizedDescription }
                }
            }
            if !authURL.isEmpty {
                Text("已在浏览器打开授权页。登录后浏览器显示空白页或错误页是正常的，复制地址栏完整 URL 粘到下面：")
                    .foregroundStyle(.secondary)
                Text(authURL).font(.caption).textSelection(.enabled)
                TextField("粘贴回调 URL", text: $callbackURL)
                Button("确认并添加") {
                    API.request("/api/auth/callback", method: "POST",
                                body: ["flow": "pkce", "callbackUrl": callbackURL]) { r in
                        if case .success = r { authURL = ""; callbackURL = ""; load() }
                        else if case .failure(let e) = r { error = e.localizedDescription }
                    }
                }
            }
            Button("刷新全部账号状态") {
                API.request("/api/accounts/refresh", method: "POST") { _ in load() }
            }
            HStack {
                Button("导出账号") { exportAccounts() }
                Button("导入账号") { importAccounts() }
            }
            Text("导出文件是明文，里面有账号的刷新令牌，拿到文件的人就能用这些账号，存好别外传。")
                .font(.caption).foregroundStyle(.secondary)
            if !notice.isEmpty { Text(notice).foregroundStyle(.secondary) }
            ForEach(accounts.indices, id: \.self) { i in
                let ac = accounts[i]
                HStack {
                    Text("\(ac["email"] as? String ?? ac["id"] as? String ?? "—") · \(ac["status"] as? String ?? "—")")
                    Spacer()
                    Button("删除") {
                        API.request("/api/accounts/delete", method: "POST",
                                    body: ["id": ac["id"] as? String ?? ""]) { _ in load() }
                    }
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .onAppear { load() }
    }

    private func load() {
        API.request("/api/accounts") { r in
            if case .success(let d) = r { accounts = d["accounts"] as? [[String: Any]] ?? [] }
        }
    }

    private func exportAccounts() {
        notice = ""; error = ""
        API.request("/api/accounts/export") { r in
            switch r {
            case .success(let d):
                guard let data = try? JSONSerialization.data(
                    withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else {
                    error = "导出失败：网关返回的数据无法保存"
                    return
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "m365hub-accounts.json"
                panel.allowedContentTypes = [UTType.json]
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        try data.write(to: url)
                        let n = (d["accounts"] as? [[String: Any]])?.count ?? 0
                        var msg = "已导出 \(n) 个账号到 \(url.lastPathComponent)"
                        if let skipped = d["skipped"] as? [String], !skipped.isEmpty {
                            msg += "，\(skipped.count) 个因令牌无法解密未导出"
                        }
                        notice = msg
                    } catch {
                        self.error = "保存失败：\(error.localizedDescription)"
                    }
                }
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }

    private func importAccounts() {
        notice = ""; error = ""
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["accounts"] as? [[String: Any]] else {
                error = "导入失败：文件里没有 accounts 列表"
                return
            }
            API.request("/api/accounts/import", method: "POST", body: ["accounts": list]) { r in
                switch r {
                case .success(let d):
                    let n = d["imported"] as? Int ?? 0
                    let errs = d["errors"] as? [String] ?? []
                    notice = errs.isEmpty
                        ? "已导入 \(n) 个账号"
                        : "已导入 \(n) 个，\(errs.count) 个失败：\(errs.joined(separator: "；"))"
                    load()
                case .failure(let e):
                    error = e.localizedDescription
                }
            }
        } catch {
            self.error = "读取文件失败：\(error.localizedDescription)"
        }
    }
}

struct KeysView: View {
    @State private var keys: [[String: Any]] = []
    @State private var error = ""
    @State private var newPlaintext = ""
    @State private var copied = false
    var body: some View {
        SectionPage(title: "API Keys", subtitle: "给外部客户端用的网关密钥") {
            Button("新建 Key") {
                API.request("/api/admin/keys", method: "POST", body: ["name": "default"]) { r in
                    if case .success(let d) = r {
                        newPlaintext = d["plaintext"] as? String ?? ""
                        copied = false
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(newPlaintext, forType: .string)
                        load()
                    } else if case .failure(let e) = r { error = e.localizedDescription }
                }
            }
            // The plaintext exists only at creation: the gateway stores
            // just a hash afterwards, so an old key can never be shown
            // again. Show the new key in full until the user leaves.
            if !newPlaintext.isEmpty {
                Text("新密钥只显示一次，已复制到剪贴板，也可点下面按钮再复制：")
                    .foregroundStyle(.secondary)
                Text(newPlaintext).font(.callout.monospaced()).textSelection(.enabled)
                Button(copied ? "已复制 ✓" : "复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(newPlaintext, forType: .string)
                    copied = true
                }
            }
            Text("列表里的密钥只存了前 12 位和哈希，完整密钥无法再查看；需要的话删掉重建一个。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(keys.indices, id: \.self) { i in
                let k = keys[i]
                HStack {
                    Text("\(k["name"] as? String ?? "—") · \(k["prefix"] as? String ?? "")…")
                    Spacer()
                    Button("删除") {
                        API.request("/api/admin/keys/delete", method: "POST",
                                    body: ["id": k["id"] as? String ?? ""]) { _ in load() }
                    }
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .onAppear { load() }
    }

    private func load() {
        API.request("/api/admin/keys") { r in
            if case .success(let d) = r { keys = d["keys"] as? [[String: Any]] ?? [] }
        }
    }
}

struct ProxiesView: View {
    @State private var proxies: [[String: Any]] = []
    @State private var url = ""
    @State private var error = ""
    var body: some View {
        SectionPage(title: "代理池", subtitle: "未配置代理时直连上游") {
            HStack {
                TextField("代理 URL，例如 http://127.0.0.1:7890", text: $url)
                Button("添加代理") {
                    API.request("/api/proxies", method: "POST", body: ["url": url]) { _ in url = ""; load() }
                }
            }
            ForEach(proxies.indices, id: \.self) { i in
                let p = proxies[i]
                let u = p["url"] as? String ?? p["raw"] as? String ?? ""
                HStack {
                    Text("\(u) · \((p["healthy"] as? Bool ?? true) ? "可用" : "不可用")")
                    Spacer()
                    Button("移除") {
                        API.request("/api/proxies/delete", method: "POST", body: ["url": u]) { _ in load() }
                    }
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .onAppear { load() }
    }

    private func load() {
        API.request("/api/proxies") { r in
            if case .success(let d) = r { proxies = d["proxies"] as? [[String: Any]] ?? [] }
        }
    }
}

struct UsageView: View {
    @State private var lines: [String] = []
    var body: some View {
        SectionPage(title: "用量统计", subtitle: "7 日用量") {
            ForEach(lines, id: \.self) { Row(text: $0) }
        }
        .onAppear {
            API.request("/api/usage?days=7") { r in
                guard case .success(let d) = r, let t = d["totals"] as? [String: Any] else { return }
                let rate = (t["hitRate"] as? Double ?? 0) * 100
                lines = [
                    "请求：\(t["requests"] as? Int ?? 0)",
                    "命中率：\(Int(rate))%",
                    "节省 Token：\(t["savedTokens"] as? Int ?? 0)",
                    "输入 Token：\(t["promptTokens"] as? Int ?? 0)",
                    "输出 Token：\(t["outputTokens"] as? Int ?? 0)",
                ]
            }
        }
    }
}

struct ModelsView: View {
    @State private var models: [String] = []
    var body: some View {
        SectionPage(title: "模型", subtitle: "网关注册的模型列表") {
            ForEach(models, id: \.self) { Row(text: $0) }
        }
        .onAppear { API.models { models = $0 } }
    }
}

struct MemoryView: View {
    @State private var memories: [[String: Any]] = []
    @State private var selectedKey = ""
    @State private var detail = ""
    @State private var loadingDetail = false
    @State private var error = ""
    @State private var notice = ""

    var body: some View {
        SectionPage(title: "本地记忆", subtitle: "网关本地项目记忆（按标签与会话分开存储），点一条看具体内容") {
            Button("刷新") { load() }
            if memories.isEmpty && error.isEmpty {
                Text("还没有本地记忆").foregroundStyle(.secondary)
            }
            ForEach(memories.indices, id: \.self) { i in
                let m = memories[i]
                let key = m["key"] as? String ?? ""
                HStack {
                    Button {
                        show(key)
                    } label: {
                        Text("\(key) · \(m["turns"] as? Int ?? 0) 轮 · \(m["chars"] as? Int ?? 0) 字 · \((m["hasSummary"] as? Bool ?? false) ? "已压缩" : "未压缩")")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("删除") {
                        API.request("/api/local-memory?key=\(encoded(key))", method: "DELETE") { r in
                            switch r {
                            case .success:
                                notice = "已删除 \(key)"
                                if selectedKey == key { selectedKey = ""; detail = "" }
                                load()
                            case .failure(let e):
                                error = e.localizedDescription
                            }
                        }
                    }
                }
            }
            if !selectedKey.isEmpty {
                Text("记忆：\(selectedKey)").font(.title2)
                if loadingDetail {
                    Text("正在读取…").foregroundStyle(.secondary)
                } else if detail.isEmpty {
                    Text("这条记忆没有内容").foregroundStyle(.secondary)
                } else {
                    Text(detail)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !notice.isEmpty { Text(notice).foregroundStyle(.secondary) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .onAppear { load() }
    }

    private func encoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    private func load() {
        error = ""; notice = ""
        API.request("/api/local-memory") { r in
            if case .success(let d) = r {
                memories = d["memories"] as? [[String: Any]] ?? []
            } else if case .failure(let e) = r {
                error = e.localizedDescription
            }
        }
    }

    private func show(_ key: String) {
        selectedKey = key
        detail = ""
        loadingDetail = true
        error = ""
        API.request("/api/local-memory?key=\(encoded(key))") { r in
            loadingDetail = false
            switch r {
            case .success(let d):
                var parts: [String] = []
                if let summary = d["summary"] as? String, !summary.isEmpty {
                    parts.append("[摘要]\n\(summary)")
                }
                if let turns = d["turns"] as? [[String: Any]] {
                    for t in turns {
                        let role = t["role"] as? String ?? ""
                        let content = t["content"] as? String ?? ""
                        parts.append("[\(role)] \(content)")
                    }
                }
                detail = parts.joined(separator: "\n\n")
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }
}

struct SystemView: View {
    @State private var line = "正在读取…"
    var body: some View {
        SectionPage(title: "系统", subtitle: "版本与运行信息") {
            Row(text: line)
        }
        .onAppear {
            API.request("/api/version") { r in
                if case .success(let d) = r { line = "版本：\(d["version"] as? String ?? d.description)" }
                else { line = "版本接口不可用（旧网关），其余功能不受影响" }
            }
        }
    }
}

struct SettingsView: View {
    var onLogout: () -> Void
    @State private var current = ""
    @State private var next = ""
    @State private var error = ""
    @AppStorage("m365hub-dark") private var dark = false

    var body: some View {
        SectionPage(title: "设置", subtitle: "控制台设置") {
            Toggle("深色模式", isOn: $dark)
            SecureField("当前密码", text: $current)
            SecureField("新密码（至少 8 位）", text: $next)
            Button("修改管理员密码") {
                API.request("/api/admin/password", method: "POST",
                            body: ["current": current, "next": next]) { r in
                    if case .failure(let e) = r { error = e.localizedDescription }
                }
            }
            Button("退出登录") {
                API.request("/api/admin/logout", method: "POST") { _ in onLogout() }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
    }
}
