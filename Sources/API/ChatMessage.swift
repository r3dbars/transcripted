// ChatMessage.swift
// Model for chat messages in the Agent tab's free-form chat feature.

import Foundation

enum ChatRole: Equatable {
    case user
    case assistant
    case tool       // Inline tool use indicator (e.g., "Reading style.md")
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: ChatRole
    var text: String        // Mutable — grows during streaming for assistant messages
    let timestamp: Date
    var isStreaming: Bool
    var toolDetail: String? // For .tool role — expandable detail (file path, command, etc.)

    init(role: ChatRole, text: String, id: String = UUID().uuidString, toolDetail: String? = nil) {
        self.role = role
        self.text = text
        self.id = id
        self.timestamp = Date()
        self.isStreaming = false
        self.toolDetail = toolDetail
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.isStreaming == rhs.isStreaming
    }
}
