import Foundation

// Chat history persisted under ~/Library/Application Support/M365Hub,
// mirroring the web console's localStorage history (text only: uploaded
// image data URLs are stripped on save, generated-image server URLs kept).
struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var role: String
    var content: String
    var images: [String] = []
    var attImages: [String] = []
}

struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title: String = "新对话"
    var createdAt = Date()
    var messages: [ChatMessage] = []
}

final class ChatStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var currentID: UUID?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("M365Hub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chat-history.json")
    }

    init() { load() }

    var current: Conversation? {
        get { conversations.first { $0.id == currentID } }
        set {
            guard let c = newValue,
                  let i = conversations.firstIndex(where: { $0.id == c.id }) else { return }
            conversations[i] = c
        }
    }

    func newConversation() -> Conversation {
        let c = Conversation()
        conversations.insert(c, at: 0)
        currentID = c.id
        save()
        return c
    }

    func ensureCurrent() -> Conversation {
        if let c = current { return c }
        return newConversation()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = nil }
        save()
    }

    func save() {
        var trimmed = conversations
        if trimmed.count > 30 { trimmed = Array(trimmed.prefix(30)) }
        struct File: Codable { var currentID: UUID?; var list: [Conversation] }
        let data = try? JSONEncoder().encode(File(currentID: currentID, list: trimmed))
        try? data?.write(to: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        struct File: Codable { var currentID: UUID?; var list: [Conversation] }
        guard let f = try? JSONDecoder().decode(File.self, from: data) else { return }
        conversations = f.list
        currentID = f.currentID
    }
}
