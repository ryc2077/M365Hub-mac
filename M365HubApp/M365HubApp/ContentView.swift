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
                if gateway.ready {
                    ContentView(store: store)
                        .preferredColorScheme(dark ? .dark : .light)
                } else {
                    VStack { ProgressView(); Text("正在启动本地网关…") }
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
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        Group {
            if loggedIn == true {
                mainView
            } else {
                LoginView(mustChange: $mustChange, password: $password, error: $error, loggingIn: $loggingIn) {
                    guard !loggingIn else { return }
                    loggingIn = true
                    error = ""
                    API.login(password: password) { r in
                        loggingIn = false
                        switch r {
                        case .success(let mc):
                            if mc { mustChange = true }
                            else { loggedIn = true; password = "" }
                        case .failure(let e):
                            error = e.localizedDescription
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
                    .disabled(loggingIn)
                Button(loggingIn ? "正在登录…" : "登录", action: onLogin)
                    .disabled(loggingIn)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .padding(40)
        .frame(maxWidth: 420)
    }
}
