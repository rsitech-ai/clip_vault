import Foundation

public enum ClipKind: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case code
    case sql
    case url
    case richText
    case image
    case file
    case error
    case unknown

    public var title: String {
        switch self {
        case .text: "Text"
        case .code: "Code"
        case .sql: "SQL"
        case .url: "Links"
        case .richText: "Rich Text"
        case .image: "Images"
        case .file: "Files"
        case .error: "Errors"
        case .unknown: "Unsorted"
        }
    }
}

public struct ClipPayload: Codable, Hashable, Sendable {
    public var kind: ClipKind
    public var displayText: String
    public var extractedText: String
    public var metadata: [String: String]
    public var previewData: Data?
    public var uniformTypeIdentifiers: [String]

    public init(
        kind: ClipKind,
        displayText: String,
        extractedText: String,
        metadata: [String: String] = [:],
        previewData: Data? = nil,
        uniformTypeIdentifiers: [String] = []
    ) {
        self.kind = kind
        self.displayText = displayText
        self.extractedText = extractedText
        self.metadata = metadata
        self.previewData = previewData
        self.uniformTypeIdentifiers = uniformTypeIdentifiers
    }
}

public extension ClipPayload {
    var searchableText: String {
        let extracted = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extracted.isEmpty {
            return extracted
        }

        let display = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !display.isEmpty, display != "Image" {
            return display
        }

        if let previewData {
            return previewData.base64EncodedString()
        }

        return kind.rawValue
    }
}

public struct Clip: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var createdAt: Date
    public var updatedAt: Date
    public var kind: ClipKind
    public var title: String
    public var preview: String
    public var extractedText: String
    public var isPinned: Bool
    public var collectionIDs: [String]
    public var pinboardIDs: [String]
    public var sourceApp: String?
    public var fingerprint: UInt64
    public var previewData: Data?
    public var metadata: [String: String]
    public var userNote: String
    public var tags: [String]
    public var copyCount: Int

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        kind: ClipKind,
        title: String,
        preview: String,
        extractedText: String,
        isPinned: Bool = false,
        collectionIDs: [String] = [],
        pinboardIDs: [String] = [],
        sourceApp: String? = nil,
        fingerprint: UInt64 = 0,
        previewData: Data? = nil,
        metadata: [String: String] = [:],
        userNote: String = "",
        tags: [String] = [],
        copyCount: Int = 1
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.kind = kind
        self.title = title
        self.preview = preview
        self.extractedText = extractedText
        self.isPinned = isPinned
        self.collectionIDs = collectionIDs
        self.pinboardIDs = pinboardIDs
        self.sourceApp = sourceApp
        self.fingerprint = fingerprint
        self.previewData = previewData
        self.metadata = metadata
        self.userNote = userNote
        self.tags = tags
        self.copyCount = max(1, copyCount)
    }
}

public extension Clip {
    var searchableContent: String {
        [
            title,
            preview,
            extractedText,
            userNote,
            tags.joined(separator: " ")
        ]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    static func makeForTests(
        createdAt: Date,
        isPinned: Bool = false,
        pinboardIDs: [String] = []
    ) -> Clip {
        Clip(
            createdAt: createdAt,
            updatedAt: createdAt,
            kind: .text,
            title: "Test clip",
            preview: "Test clip",
            extractedText: "Test clip",
            isPinned: isPinned,
            pinboardIDs: pinboardIDs
        )
    }
}

public struct ClipCollection: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var systemImage: String
    public var kind: ClipKind?
    public var isSmart: Bool

    public init(id: String, title: String, systemImage: String, kind: ClipKind?, isSmart: Bool = true) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.isSmart = isSmart
    }

    public static let defaults: [ClipCollection] = [
        ClipCollection(id: "all", title: "All Clips", systemImage: "tray.full", kind: nil),
        ClipCollection(id: "code", title: "Code", systemImage: "curlybraces", kind: .code),
        ClipCollection(id: "sql", title: "SQL", systemImage: "tablecells", kind: .sql),
        ClipCollection(id: "errors", title: "Errors", systemImage: "exclamationmark.triangle", kind: .error),
        ClipCollection(id: "research", title: "Research", systemImage: "doc.text.magnifyingglass", kind: .text),
        ClipCollection(id: "links", title: "Links", systemImage: "link", kind: .url),
        ClipCollection(id: "drafts", title: "Drafts", systemImage: "text.append", kind: .richText),
        ClipCollection(id: "images", title: "Images", systemImage: "photo", kind: .image),
        ClipCollection(id: "files", title: "Files", systemImage: "folder", kind: .file)
    ]
}

public struct CollectionFolder: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var collectionID: String?
    public var children: [CollectionFolder]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        collectionID: String? = nil,
        children: [CollectionFolder] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.collectionID = collectionID
        self.children = children
        self.createdAt = createdAt
    }

    public func path(in root: CollectionFolder) -> String? {
        if id == root.id {
            return root.title
        }

        return root.path(to: id)
    }

    private func path(to targetID: String) -> String? {
        if id == targetID {
            return title
        }

        for child in children {
            if let childPath = child.path(to: targetID) {
                return "\(title) / \(childPath)"
            }
        }

        return nil
    }

    public static let defaults: [CollectionFolder] = [
        CollectionFolder(
            title: "Collections",
            children: ClipCollection.defaults.map {
                CollectionFolder(title: $0.title, collectionID: $0.id)
            }
        )
    ]
}

public struct Pinboard: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, title: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }
}
