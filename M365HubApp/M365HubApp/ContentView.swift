import SwiftUI
import AppKit

@main
struct M365HubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var gateway = GatewayManager.shared
    @StateObject private var store = ChatStore()
    @AppStorage("m365hub-dark") private var dark = false

    var body: some Scene {
        WindowGroup {
            Group {
                if let failure = gateway.failure {
                    // 1.0.28: the gateway failed to start (or a login
                    // timed out twice). Show the failure screen with the
                    // real cause and the log tail instead of a login
                    // screen that can never log in.
                    GatewayFailureView(failure: failure, logURL: gateway.logFileURL, onForceClean: {
                        gateway.forceCleanAndRetry()
                    }) {
                        gateway.start()
                    }
                    .preferredColorScheme(dark ? .dark : .light)
                } else if gateway.ready {
                    ContentView(store: store)
                        .preferredColorScheme(dark ? .dark : .light)
                } else {
                    VStack {
                        ProgressView()
                        Text(gateway.recovering ? "正在恢复本地网关…" : "正在启动本地网关…")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Startup lives here, not in ContentView.onAppear: ContentView
            // only exists once gateway.ready is true, so starting there
            // deadlocked on the spinner forever (1.0.12, proven in CI).
            .onAppear { gateway.start() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新对话") { _ = store.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        GatewayManager.shared.stopIfOwned()
    }
}

enum Section: String, CaseIterable, Identifiable {
    case chat = "聊天"
    case dashboard = "仪表盘"
    case accounts = "账号"
    case keys = "API Keys"
    case proxies = "代理池"
    case usage = "用量统计"
    case models = "模型"
    case memory = "本地记忆"
    case system = "系统"
    case settings = "设置"

    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var store: ChatStore
    @State private var section: Section = .chat
    @State private var loggedIn: Bool?
    @State private var mustChange = false
    @State private var password = ""
    @State private var error = ""
    @State private var loggingIn = false
    @State private var healing = false
    @State private var healedOnce = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        Group {
            if loggedIn == true {
                mainView
            } else {
                LoginView(mustChange: $mustChange, password: $password, error: $error, loggingIn: $loggingIn, healing: $healing) {
                    guard !loggingIn else { return }
                    loggingIn = true
                    error = ""
                    API.login(password: password) { r in
                        switch r {
                        case .success(let mc):
                            loggingIn = false
                            if mc { mustChange = true }
                            else { loggedIn = true; password = "" }
                        case .failure(let e):
                            // 1.0.28: a login that times out means the
                            // gateway on 8230 accepts TCP but never
                            // answers — the hung gateway the user hit in
                            // 1.0.27. Heal it once (clear a hung m365hub,
                            // restart the bundled gateway, retry the
                            // login automatically) instead of leaving a
                            // bare "The request timed out." on the
                            // screen. A second timeout is a real
                            // failure, not a retry loop.
                            if (e as? URLError)?.code == .timedOut, !healedOnce {
                                healedOnce = true
                                healing = true
                                error = ""
                                GatewayManager.shared.healAfterLoginTimeout(password: password) { outcome in
                                    healing = false
                                    loggingIn = false
                                    switch outcome {
                                    case .loggedIn(let mc):
                                        if mc { mustChange = true }
                                        else { loggedIn = true; password = "" }
                                    case .failed(let msg):
                                        error = msg
                                    }
                                }
                            } else {
                                loggingIn = false
                                error = e.localizedDescription
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            // Gateway startup is driven by the App's WindowGroup onAppear:
            // this view only exists once the gateway is ready, so calling
            // start() here deadlocked on the spinner (see 1.0.12).
            API.session { loggedIn = $0 }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    // Split from body: one giant Group with the split view, the history
    // list and the nine-way detail switch made the type checker time out
    // ("unable to type-check this expression in reasonable time").
    // Each piece below type-checks on its own.
    private var mainView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: {
                    columnVisibility = columnVisibility == .all ? .detailOnly : .all
                }) {
                    Image(systemName: "sidebar.left")
                }
                .help("历史对话")
            }
        }
    }

    private var sidebar: some View {
        List(selection: $section) {
            SwiftUI.Section("历史对话") {
                Button("＋ 新对话") { _ = store.newConversation(); section = .chat }
                ForEach(store.conversations) { c in
                    HStack {
                        Text(c.title).lineLimit(1)
                        Spacer()
                        Button("×") { store.delete(c.id) }
                            .buttonStyle(.plain)
                    }
                    .tag(Section.chat)
                    .onTapGesture {
                        store.currentID = c.id
                        section = .chat
                    }
                }
            }
            SwiftUI.Section("功能") {
                ForEach(Section.allCases.filter { $0 != .chat }) { s in
                    Text(s.rawValue).tag(s)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    @ViewBuilder
    private var detailView: some View {
        switch section {
        case .chat: ChatView(store: store)
        case .dashboard: DashboardView()
        case .accounts: AccountsView()
        case .keys: KeysView()
        case .proxies: ProxiesView()
        case .usage: UsageView()
        case .models: ModelsView()
        case .memory: MemoryView()
        case .system: SystemView()
        case .settings: SettingsView(onLogout: { loggedIn = false })
        }
    }
}

struct LoginView: View {
    @Binding var mustChange: Bool
    @Binding var password: String
    @Binding var error: String
    @Binding var loggingIn: Bool
    @Binding var healing: Bool
    var onLogin: () -> Void
    @State private var current = ""
    @State private var next = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("M365Hub").font(.largeTitle)
            if mustChange {
                SecureField("当前密码", text: $current)
                SecureField("新密码（至少 8 位）", text: $next)
                Button("修改密码并登录") {
                    API.request("/api/admin/password", method: "POST",
                                body: ["current": current, "next": next]) { r in
                        if case .success = r { mustChange = false }
                        else if case .failure(let e) = r { error = e.localizedDescription }
                    }
                }
            } else {
                SecureField("管理员密码", text: $password)
                    .onSubmit(onLogin)
                    .disabled(loggingIn || healing)
                Button(healing ? "正在恢复本地网关…" : (loggingIn ? "正在登录…" : "登录"), action: onLogin)
                    .disabled(loggingIn || healing)
                if healing {
                    Text("登录超时，正在清理卡死的网关并自动重登，请稍等…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .padding(40)
        .frame(maxWidth: 420)
    }
}

// 1.0.28: shown instead of the login screen when the gateway could
// not be started (or a login timed out twice). Everything on it is
// written so a screenshot sent back to the developer is enough to
// locate the cause: the real reason, the port occupant, and the
// gateway log tail.
// 1.0.29: adds a "强制清理并重试" button for a confirmed same-user
// m365hub occupant — one tap re-runs the SIGKILL escalation and
// restarts the gateway. A foreign process (or another user's) never
// gets the button: the app must not kill what it does not own.
struct GatewayFailureView: View {
    let failure: GatewayFailure
    let logURL: URL
    var onRetry: () -> Void
    var onForceClean: () -> Void = {}
    @State private var copied = false
    @State private var forceTapped = false

    // Only a same-user m365hub occupant can be force-cleaned. uid nil
    // means ps could not tell; the escalation itself re-checks the
    // occupant before signalling, so showing the button is safe.
    private var canForceClean: Bool {
        guard failure.occupantName == "m365hub" else { return false }
        guard let uid = failure.occupantUID else { return true }
        return uid == GatewayDiagnostics.currentUID()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("本地网关起不来").font(.largeTitle)
                Text(failure.title).font(.headline)
                Text(failure.reason)
                Text("网关日志末尾（serve-mac.log）：").font(.headline)
                Text(failure.logTail.isEmpty ? "（暂无日志）" : failure.logTail)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(8)
                HStack(spacing: 12) {
                    Button("重试", action: onRetry)
                    if canForceClean {
                        Button(forceTapped ? "正在强制清理…" : "强制清理并重试") {
                            forceTapped = true
                            onForceClean()
                        }
                        .disabled(forceTapped)
                    }
                    Button("查看完整日志") {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    }
                    Button(copied ? "已复制" : "复制诊断信息") {
                        NSPasteboard.general.clearContents()
                        _ = NSPasteboard.general.setString(failure.diagnosticText, forType: .string)
                        copied = true
                    }
                }
                Text("把这屏截图发给开发者，就能定位问题。")
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
