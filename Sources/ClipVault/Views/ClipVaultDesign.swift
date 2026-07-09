import ClipVaultCore
import SwiftUI

enum ClipVaultDesign {
    static let panelRadius: CGFloat = 18
    static let sectionRadius: CGFloat = 14
    static let controlRadius: CGFloat = 10

    static func icon(for kind: ClipKind) -> String {
        switch kind {
        case .text: "doc.text"
        case .code: "curlybraces"
        case .sql: "tablecells"
        case .url: "link"
        case .richText: "text.append"
        case .image: "photo"
        case .file: "folder"
        case .error: "exclamationmark.triangle"
        case .unknown: "doc"
        }
    }

    static func tint(for kind: ClipKind) -> Color {
        switch kind {
        case .text: .secondary
        case .code, .sql: .blue
        case .url: .teal
        case .richText: .indigo
        case .image: .pink
        case .file: .orange
        case .error: .red
        case .unknown: .secondary
        }
    }

    static func icon(for action: AIActionKind) -> String {
        switch action {
        case .summarize: "text.alignleft"
        case .explain: "questionmark.bubble"
        case .email: "envelope"
        case .todos: "checklist"
        case .ask: "arrow.up.circle"
        }
    }

    static func tint(for action: AIActionKind) -> Color {
        switch action {
        case .summarize: .cyan
        case .explain: .indigo
        case .email: .teal
        case .todos: .green
        case .ask: .accentColor
        }
    }

    static func hint(for action: AIActionKind) -> String {
        switch action {
        case .summarize:
            "Condense selected clips into the key points."
        case .explain:
            "Explain what the selected clip means and why it matters."
        case .email:
            "Draft a clear email from the selected clip context."
        case .todos:
            "Extract concrete follow-up tasks from selected clips."
        case .ask:
            "Ask a custom question about the selected clips."
        }
    }
}
