import Foundation

public struct Snippet: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var content: String
    public var enabled: Bool
    public init(id: UUID = UUID(), title: String, content: String, enabled: Bool = true) {
        self.id = id; self.title = title; self.content = content; self.enabled = enabled
    }
}

public struct SnippetFolder: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var enabled: Bool
    public var snippets: [Snippet]
    public init(id: UUID = UUID(), title: String, enabled: Bool = true, snippets: [Snippet] = []) {
        self.id = id; self.title = title; self.enabled = enabled; self.snippets = snippets
    }
}
