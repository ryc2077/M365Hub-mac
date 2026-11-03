import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Chat, the launch screen (like the Copilot app: one tap in and you
// are chatting). User messages are right-aligned grey pills, assistant
// messages plain text, input bar is a liquid-glass capsule.
struct ChatView: View {
    @ObservedObject var store: ChatStore
    @State private var text = ""
    @State private var models: [String] = []
    @State private var model: String = ""
    @State private var accounts: [(id: String, label: String)] = []
    @State private var chatAccount = "" // "" = 轮询全部账号；选了就只用这个号聊天
    @State private var mode = 0 // 0 chat, 1 image
    @State private var imageModel = "flux-4"
    @State private var sending = false
    @State private var showImagePicker = false
    @State private var showFilePicker = false
    @State private var error = ""
    @State private var atts: [Att] = []

    struct Att: Identifiable {
        var id = UUID()
        var kind: String // image | text
        var name: String
        var mime: String = ""
        var dataURL: String = ""
        var text: String = ""
    }

    var conv: Conversation { store.ensureCurrent() }

    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar: account / model / mode / image model / new chat.
            HStack {
                Picker("账号", selection: $chatAccount) {
                    Text("轮询").tag("")
                    ForEach(accounts, id: \.id) { Text($0.label).tag($0.id) }
                }
                .frame(maxWidth: 130)
                .onChange(of: chatAccount) {
                    UserDefaults.standard.set(chatAccount, forKey: "m365hub-chat-account")
                }
                Picker("模型", selection: $model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 220)
                Picker("", selection: $mode) {
                    Text("聊天").tag(0)
                    Text("生成图片").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
                if mode == 1 {
                    Picker("", selection: $imageModel) {
                        Text("flux-4").tag("flux-4")
                        Text("flux-3").tag("flux-3")
                    }
                    .frame(maxWidth: 110)
                }
                Spacer()
                Button("＋ 新对话") {
                    _ = store.newConversation()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    if conv.messages.isEmpty {
                        VStack(spacing: 16) {
                            Text("你好，今天想聊点什么？")
                                .font(.largeTitle)
                            Text("直接在应用里聊天，不用另开客户端。历史在左侧边栏，点一条回到那段对话。")
                                .foregroundStyle(.secondary)
                            ForEach(["解方程 x^2 - 5x + 6 = 0", "写一首关于秋天的诗",
                                     "用 Python 写一个快速排序", "帮我润色一段自我介绍"], id: \.self) { t in
                                Button(t) { text = t; send() }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(conv.messages) { m in
                                MessageRow(message: m)
                                    .id(m.id)
                            }
                        }
                        .padding()
                    }
                }
                .onChange(of: conv.messages.count) {
                    if let last = conv.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if !error.isEmpty {
                Text(error).foregroundStyle(.red).padding(.horizontal)
            }
            if !atts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(atts) { a in
                            Button("\(a.name) ×") { atts.removeAll { $0.id == a.id } }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            // Liquid-glass input capsule.
            HStack(spacing: 8) {
                Menu {
                    Button("上传图片") { showImagePicker = true }
                    Button("上传文件") { showFilePicker = true }
                    Button("从照片图库选择") { showImagePicker = true }
                } label: {
                    Text("＋").font(.title3)
                }
                .menuStyle(.borderlessButton)
                TextField("Message Copilot", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onSubmit { send() }
                Button(action: send) {
                    Text("↑")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                        .liquidGlassCircle()
                }
                .buttonStyle(.plain)
                .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .liquidGlass()
            .padding()
        }
        .onAppear { loadModels() }
        .fileImporter(isPresented: $showImagePicker, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            handlePicked(result, asImage: true)
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            handlePicked(result, asImage: false)
        }
    }

    private func loadModels() {
        API.accounts { list in
            accounts = list.map { (id: $0.id, label: $0.email.split(separator: "@").first.map(String.init) ?? $0.email) }
            let saved = UserDefaults.standard.string(forKey: "m365hub-chat-account") ?? ""
            chatAccount = accounts.contains { $0.id == saved } ? saved : ""
        }
        API.models { ids in
            models = ids
            let saved = UserDefaults.standard.string(forKey: "m365hub-chat-model")
            if let saved = saved, ids.contains(saved) { model = saved }
            else if ids.contains("gpt-5.6-reasoning") { model = "gpt-5.6-reasoning" }
            else if ids.contains("gpt-4-auto") { model = "gpt-4-auto" }
            else if let first = ids.first { model = first }
        }
    }

    private func handlePicked(_ result: Result<[URL], Error>, asImage: Bool) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            if asImage || (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false) {
                var bytes = data
                var mime = "image/png"
                if url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg" { mime = "image/jpeg" }
                if bytes.count > 1_500_000, let img = NSImage(data: data) {
                    // Downscale large photos before base64-encoding.
                    let maxSide: CGFloat = 1568
                    let size = img.size
                    let scale = min(1, maxSide / max(size.width, size.height))
                    let newSize = NSSize(width: size.width * scale, height: size.height * scale)
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(newSize.width),
                                               pixelsHigh: Int(newSize.height), bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                    rep?.size = newSize
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep!)
                    img.draw(in: NSRect(origin: .zero, size: newSize))
                    NSGraphicsContext.restoreGraphicsState()
                    if let jpg = rep?.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                        bytes = jpg
                        mime = "image/jpeg"
                    }
                }
                atts.append(Att(kind: "image", name: url.lastPathComponent, mime: mime,
                                dataURL: "data:\(mime);base64,\(bytes.base64EncodedString())"))
            } else if data.count <= 512 * 1024, let text = String(data: data, encoding: .utf8) {
                atts.append(Att(kind: "text", name: url.lastPathComponent, text: text))
            } else {
                error = "不支持的文件：仅支持图片和 512KB 以内的文本文件"
            }
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        error = ""
        var conv = store.ensureCurrent()
        if conv.title == "新对话" { conv.title = String(t.prefix(20)) }
        var fullText = t
        var imgAtts: [Att] = []
        for a in atts {
            if a.kind == "text" { fullText += "\n\n```\(a.name)\n\(a.text)\n```" }
            else { imgAtts.append(a) }
        }
        let convID = conv.id
        var user = ChatMessage(role: "user", content: fullText)
        user.attImages = imgAtts.map { $0.dataURL }
        conv.messages.append(user)
        let pending = ChatMessage(role: "assistant", content: "思考中…")
        conv.messages.append(pending)
        store.current = conv
        store.save()
        text = ""
        atts = []
        sending = true
        UserDefaults.standard.set(model, forKey: "m365hub-chat-model")

        if mode == 1 {
            API.generateImage(prompt: t, model: imageModel, accountID: chatAccount) { r in
                sending = false
                guard let idx = store.conversations.firstIndex(where: { $0.id == convID }) else { return }
                store.conversations[idx].messages.removeAll { $0.id == pending.id }
                switch r {
                case .success(let (txt, imgs)):
                    store.conversations[idx].messages.append(ChatMessage(role: "assistant", content: txt, images: imgs))
                case .failure(let e):
                    store.conversations[idx].messages.append(ChatMessage(role: "assistant", content: "出错：\(e.localizedDescription)"))
                }
                store.save()
            }
            return
        }
        let history = conv.messages.dropLast().map { ["role": $0.role, "content": $0.content] }
        let attachments = imgAtts.map { ["type": "image", "url": $0.dataURL, "name": $0.name, "mimeType": $0.mime] }
        API.chat(model: model, messages: history, attachments: attachments, accountID: chatAccount) { r in
            sending = false
            guard let idx = store.conversations.firstIndex(where: { $0.id == convID }) else { return }
            store.conversations[idx].messages.removeAll { $0.id == pending.id }
            switch r {
            case .success(let content):
                store.conversations[idx].messages.append(ChatMessage(role: "assistant", content: content))
            case .failure(let e):
                store.conversations[idx].messages.append(ChatMessage(role: "assistant", content: "出错：\(e.localizedDescription)"))
            }
            store.save()
        }
    }
}

struct MessageRow: View {
    var message: ChatMessage
    @State private var loaded: [String: NSImage] = [:]
    @State private var copied = false

    var body: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 6) {
            if message.role == "user" {
                Text(message.content)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 18))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                // Native math via SwiftMath: inline formulas render into
                // the text line, display formulas are centered images,
                // code blocks stay literal. Unrenderable formulas fall
                // back to their LaTeX source text.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(assistantBlocks) { block in
                        switch block.kind {
                        case .text(let t):
                            t.frame(maxWidth: .infinity, alignment: .leading)
                        case .displayImage(let img):
                            HStack {
                                Spacer()
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 520)
                                Spacer()
                            }
                        case .code(let code):
                            Text(code)
                                .font(.system(.body, design: .monospaced))
                                .padding(10)
                                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // One-tap copy, same as Android 1.2.10: copies the plain
                // text (markdown markers stripped, formulas and code
                // blocks kept as source) and confirms briefly.
                HStack {
                    Button(copied ? "已复制全部内容" : "📋 复制全部") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plainCopyText(message.content), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
            }
            ForEach(message.images + message.attImages, id: \.self) { url in
                if let img = loaded[url] {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 320)
                } else {
                    Color.clear.frame(height: 1)
                        .onAppear {
                            API.imageData(url: url) { data in
                                if let data = data, let img = NSImage(data: data) {
                                    loaded[url] = img
                                }
                            }
                        }
                }
            }
        }
        // Free selection, same as Android 1.2.10: drag-select any part
        // of a message (assistant or your own) and copy just that bit.
        // Text views inherit this; buttons and images are unaffected.
        .textSelection(.enabled)
    }
}

// Plain text for "复制全部": strip markdown markers (bold, headings,
// list markers, single backticks) but keep formulas as $...$ source
// and code-block fences with their source, like Android 1.2.10.
private func plainCopyText(_ s: String) -> String {
    var inCode = false
    return s.components(separatedBy: "\n").map { line in
        // Code blocks (fences and everything between them) stay
        // verbatim, like Android 1.2.10 — so `a**b` is never mangled.
        if line.hasPrefix("```") {
            inCode.toggle()
            return line
        }
        if inCode { return line }
        var l = line.replacingOccurrences(of: "**", with: "")
        l = l.replacingOccurrences(of: "__", with: "")
        l = l.replacingOccurrences(of: "`", with: "")
        // Heading markers: one or more # followed by a space.
        while l.hasPrefix("#") { l.removeFirst() }
        l = l.hasPrefix(" ") ? String(l.dropFirst()) : l
        // List markers: "- " / "* " / "1. " at line start.
        if l.hasPrefix("- ") || l.hasPrefix("* ") { l = String(l.dropFirst(2)) }
        if let dot = l.firstIndex(of: "."),
           l[..<dot].allSatisfy({ $0.isNumber }),
           l.index(after: dot) < l.endIndex,
           l[l.index(after: dot)] == " " {
            l = String(l[l.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return l
    }.joined(separator: "\n")
}

// Assistant message split into renderable blocks for MessageRow.
struct AssistantBlock: Identifiable {
    let id: Int
    enum Kind {
        case text(Text)
        case displayImage(NSImage)
        case code(String)
    }
    let kind: Kind
}

extension MessageRow {
    var assistantBlocks: [AssistantBlock] {
        var blocks: [AssistantBlock] = []
        var nextID = 0
        func append(_ kind: AssistantBlock.Kind) {
            blocks.append(AssistantBlock(id: nextID, kind: kind))
            nextID += 1
        }
        var pending = Text("")
        var hasPending = false
        func flush() {
            if hasPending {
                append(.text(pending))
                pending = Text("")
                hasPending = false
            }
        }
        for seg in MathSegments.parse(message.content) {
            switch seg {
            case .text(let t):
                pending = pending + Text(t)
                hasPending = true
            case .inline(let latex):
                if let img = MathRender.image(latex: latex, fontSize: 15, display: false) {
                    pending = pending + Text("\(Image(nsImage: img))")
                } else {
                    pending = pending + Text(latex)
                }
                hasPending = true
            case .display(let latex):
                flush()
                if let img = MathRender.image(latex: latex, fontSize: 19, display: true) {
                    append(.displayImage(img))
                } else {
                    append(.text(Text(latex)))
                }
            case .code(let code):
                flush()
                append(.code(code))
            }
        }
        flush()
        return blocks
    }
}
