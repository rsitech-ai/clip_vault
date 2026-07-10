import Foundation
import SwiftData

@Model
public final class ClipRecord {
    @Attribute(.unique) public var id: String
    public var createdAt: Date
    public var updatedAt: Date
    public var kindRaw: String
    public var title: String
    public var preview: String
    public var isPinned: Bool
    public var collectionIDsRaw: String
    public var pinboardIDsRaw: String
    public var sourceApp: String?
    public var fingerprintValue: UInt64
    public var userNote: String?
    public var tagsRaw: String?
    public var copyCount: Int?
    @Attribute(.externalStorage) public var encryptedPayload: Data
    @Attribute(.externalStorage) public var encryptedListPayload: Data?

    public init(clip: Clip, encryptedPayload: Data, encryptedListPayload: Data? = nil) {
        self.id = clip.id
        self.createdAt = clip.createdAt
        self.updatedAt = clip.updatedAt
        self.kindRaw = clip.kind.rawValue
        self.title = clip.title
        self.preview = clip.preview
        self.isPinned = clip.isPinned
        self.collectionIDsRaw = clip.collectionIDs.joined(separator: ",")
        self.pinboardIDsRaw = clip.pinboardIDs.joined(separator: ",")
        self.sourceApp = clip.sourceApp
        self.fingerprintValue = clip.fingerprint
        self.userNote = clip.userNote
        self.tagsRaw = clip.tags.joined(separator: ",")
        self.copyCount = clip.copyCount
        self.encryptedPayload = encryptedPayload
        self.encryptedListPayload = encryptedListPayload
    }
}

private struct EncryptedClipDetails: Codable {
    static let currentVersion = 1

    var version: Int
    var listPayload: ClipPayload
    var title: String
    var userNote: String
    var tags: [String]
    var sourceApp: String?

    init(
        listPayload: ClipPayload,
        title: String,
        userNote: String,
        tags: [String],
        sourceApp: String?
    ) {
        self.version = Self.currentVersion
        self.listPayload = listPayload
        self.title = title
        self.userNote = userNote
        self.tags = tags
        self.sourceApp = sourceApp
    }
}

private enum EncryptedClipDetailsError: Error {
    case unsupportedVersion(Int)
}

@Model
public final class FolderRecord {
    @Attribute(.unique) public var id: String
    public var title: String
    public var collectionID: String?
    public var parentID: String?
    public var createdAt: Date
    public var sortOrder: Int

    public init(folder: CollectionFolder, parentID: String? = nil, sortOrder: Int = 0) {
        self.id = folder.id
        self.title = folder.title
        self.collectionID = folder.collectionID
        self.parentID = parentID
        self.createdAt = folder.createdAt
        self.sortOrder = sortOrder
    }
}

public protocol ClipStoring: AnyObject {
    func allClips() throws -> [Clip]
    func folders() throws -> [CollectionFolder]
    func payload(for clipID: String) throws -> ClipPayload?
    func save(payload: ClipPayload, sourceApp: String?) throws -> Clip?
    func addClips(ids: [String], toCollectionID collectionID: String) throws
    func togglePinned(id: String) throws
    func updateNote(id: String, note: String) throws
    func updateTitle(id: String, title: String) throws
    func updateTags(id: String, tags: [String]) throws
    func saveFolder(_ folder: CollectionFolder, parentID: String?, sortOrder: Int) throws
    func updateFolder(id: String, title: String, parentID: String?) throws
    func deleteFolder(id: String) throws
    func delete(id: String) throws
    func delete(ids: [String]) throws
    func pruneExpired(now: Date) throws
}

public enum FolderStoreError: Error, LocalizedError, Equatable {
    case emptyTitle
    case notFound
    case protectedFolder
    case invalidMove
    case nonLeafCreate
    case duplicateID

    public var errorDescription: String? {
        switch self {
        case .emptyTitle:
            "Folder name cannot be empty."
        case .notFound:
            "Folder no longer exists."
        case .protectedFolder:
            "Built-in workspace folders cannot be changed."
        case .invalidMove:
            "Folder cannot be moved there."
        case .nonLeafCreate:
            "Create folders one at a time; a new folder cannot include children."
        case .duplicateID:
            "A workspace item with that identifier already exists."
        }
    }
}

public enum WorkspaceFolderPolicy {
    public static func isProtected(_ folder: CollectionFolder) -> Bool {
        isProtected(
            collectionID: folder.collectionID,
            childCollectionIDs: Set(folder.children.compactMap(\.collectionID))
        )
    }

    static func isProtected(collectionID: String?, childCollectionIDs: Set<String>) -> Bool {
        if let collectionID {
            return defaultCollectionIDs.contains(collectionID)
        }
        return defaultCollectionIDs.isSubset(of: childCollectionIDs)
    }

    private static let defaultCollectionIDs = Set(ClipCollection.defaults.map(\.id))
}

public enum WorkspaceCollectionID {
    public static func make(for title: String, uuid: UUID = UUID()) -> String {
        let slug = title
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let readableSlug = slug.isEmpty ? "collection" : slug
        return "\(readableSlug)-\(uuid.uuidString.lowercased())"
    }
}

public enum WorkspaceCollectionCatalog {
    public static func rebuild(from folders: [CollectionFolder]) -> [ClipCollection] {
        var customCollections: [String: ClipCollection] = [:]

        for folder in flatten(folders) {
            guard let collectionID = folder.collectionID,
                  !ClipCollection.defaults.contains(where: { $0.id == collectionID }) else {
                continue
            }
            customCollections[collectionID] = ClipCollection(
                id: collectionID,
                title: folder.title,
                systemImage: "folder",
                kind: nil,
                isSmart: false
            )
        }

        return ClipCollection.defaults + customCollections.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private static func flatten(_ folders: [CollectionFolder]) -> [CollectionFolder] {
        folders.flatMap { folder in
            [folder] + flatten(folder.children)
        }
    }
}

enum BuiltInCollectionAssignment {
    static func ids(for kind: ClipKind) -> [String] {
        switch kind {
        case .code: ["code"]
        case .sql: ["sql", "code"]
        case .url: ["links"]
        case .richText: ["drafts"]
        case .image: ["images"]
        case .file: ["files"]
        case .error: ["errors", "code"]
        case .text: ["research"]
        case .unknown: []
        }
    }
}

enum WorkspaceFolderCreateValidator {
    static func validate(
        folder: CollectionFolder,
        parentID: String?,
        parent: CollectionFolder?,
        existingIDs: Set<String>
    ) throws -> CollectionFolder {
        let trimmedTitle = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw FolderStoreError.emptyTitle
        }
        guard folder.children.isEmpty else {
            throw FolderStoreError.nonLeafCreate
        }
        guard !existingIDs.contains(folder.id) else {
            throw FolderStoreError.duplicateID
        }
        guard parentID != folder.id else {
            throw FolderStoreError.invalidMove
        }
        if parentID != nil {
            guard let parent else {
                throw FolderStoreError.notFound
            }
            guard parent.collectionID == nil else {
                throw FolderStoreError.invalidMove
            }
        }

        return CollectionFolder(
            id: folder.id,
            title: trimmedTitle,
            collectionID: folder.collectionID,
            createdAt: folder.createdAt
        )
    }
}

public final class SwiftDataClipStore: ClipStoring {
    private let context: ModelContext
    private let encryptor: any PayloadEncrypting
    private let sensitiveRules: SensitiveRuleEngine
    private let index: any SearchIndexing
    private let retentionPolicy: RetentionPolicy
    private let saveFolderContext: (ModelContext) throws -> Void
    private let previewTransformer: (Data) -> Data?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        context: ModelContext,
        encryptor: any PayloadEncrypting = LocalPayloadEncryptor(),
        sensitiveRules: SensitiveRuleEngine = .default,
        index: any SearchIndexing = RustSearchIndexCore(),
        retentionPolicy: RetentionPolicy = .default
    ) {
        self.context = context
        self.encryptor = encryptor
        self.sensitiveRules = sensitiveRules
        self.index = index
        self.retentionPolicy = retentionPolicy
        self.saveFolderContext = { try $0.save() }
        self.previewTransformer = ClipPreviewThumbnailer.thumbnailData
    }

    init(
        context: ModelContext,
        encryptor: any PayloadEncrypting = LocalPayloadEncryptor(),
        saveContext: @escaping (ModelContext) throws -> Void,
        previewTransformer: @escaping (Data) -> Data? = ClipPreviewThumbnailer.thumbnailData
    ) {
        self.context = context
        self.encryptor = encryptor
        self.sensitiveRules = .default
        self.index = RustSearchIndexCore()
        self.retentionPolicy = .default
        self.saveFolderContext = saveContext
        self.previewTransformer = previewTransformer
    }

    public func allClips() throws -> [Clip] {
        let descriptor = FetchDescriptor<ClipRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let clips = try context.fetch(descriptor).compactMap(recordToClip)
        if context.hasChanges {
            try context.save()
        }
        return clips
    }

    public func folders() throws -> [CollectionFolder] {
        let descriptor = FetchDescriptor<FolderRecord>(
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.createdAt)
            ]
        )
        let records = try context.fetch(descriptor)
        if records.isEmpty {
            try seedDefaultFolders()
            return try folders()
        }

        return folderTree(from: records, parentID: nil)
    }

    public func payload(for clipID: String) throws -> ClipPayload? {
        let descriptor = FetchDescriptor<ClipRecord>(
            predicate: #Predicate { record in record.id == clipID }
        )
        guard let record = try context.fetch(descriptor).first else {
            return nil
        }

        _ = try details(from: record)
        if context.hasChanges {
            try context.save()
        }
        return try payload(from: record)
    }

    public func save(payload: ClipPayload, sourceApp: String? = nil) throws -> Clip? {
        let classification = sensitiveRules.classify(payload.extractedText)
        guard !classification.isExcluded else {
            return nil
        }

        let fingerprint = index.fingerprint(payload.searchableText)
        let existingDescriptor = FetchDescriptor<ClipRecord>(
            predicate: #Predicate { record in record.fingerprintValue == fingerprint }
        )
        let existing = try context.fetch(existingDescriptor).first

        if let existing {
            var details = try details(from: existing)
            existing.copyCount = (existing.copyCount ?? 1) + 1
            existing.updatedAt = Date()
            let data = try encoder.encode(payload)
            existing.encryptedPayload = try encryptor.encrypt(data)
            details.listPayload = listPayload(for: payload)
            existing.encryptedListPayload = try encryptedDetailsPayload(details)
            clearPlaintextDetails(on: existing)
            try context.save()
            return try recordToClip(existing)
        }

        let listPayload = listPayload(for: payload)
        let clip = Clip(
            kind: listPayload.kind,
            title: title(for: listPayload),
            preview: listPayload.displayText,
            extractedText: listPayload.extractedText,
            collectionIDs: BuiltInCollectionAssignment.ids(for: listPayload.kind),
            sourceApp: sourceApp,
            fingerprint: fingerprint,
            previewData: listPayload.previewData,
            metadata: listPayload.metadata
        )

        let data = try encoder.encode(payload)
        let encrypted = try encryptor.encrypt(data)
        let encryptedDetails = try encryptedDetailsPayload(EncryptedClipDetails(
            listPayload: listPayload,
            title: clip.title,
            userNote: clip.userNote,
            tags: clip.tags,
            sourceApp: clip.sourceApp
        ))
        let record = ClipRecord(
            clip: clip,
            encryptedPayload: encrypted,
            encryptedListPayload: encryptedDetails
        )
        clearPlaintextDetails(on: record)
        context.insert(record)
        try context.save()
        return clip
    }

    public func addClips(ids: [String], toCollectionID collectionID: String) throws {
        let trimmed = collectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let idSet = Set(ids)
        guard !idSet.isEmpty else {
            return
        }

        let descriptor = FetchDescriptor<ClipRecord>()
        for record in try context.fetch(descriptor) where idSet.contains(record.id) {
            var collectionIDs = split(record.collectionIDsRaw)
            if !collectionIDs.contains(trimmed) {
                collectionIDs.append(trimmed)
                record.collectionIDsRaw = collectionIDs.joined(separator: ",")
                record.updatedAt = Date()
            }
        }
        try context.save()
    }

    public func togglePinned(id: String) throws {
        let descriptor = FetchDescriptor<ClipRecord>(
            predicate: #Predicate { record in record.id == id }
        )
        guard let record = try context.fetch(descriptor).first else {
            return
        }

        record.isPinned.toggle()
        record.updatedAt = Date()
        try context.save()
    }

    public func updateNote(id: String, note: String) throws {
        let descriptor = FetchDescriptor<ClipRecord>(
            predicate: #Predicate { record in record.id == id }
        )
        guard let record = try context.fetch(descriptor).first else {
            return
        }

        var details = try details(from: record)
        details.userNote = note
        record.encryptedListPayload = try encryptedDetailsPayload(details)
        clearPlaintextDetails(on: record)
        record.updatedAt = Date()
        try context.save()
    }

    public func updateTitle(id: String, title: String) throws {
        let descriptor = FetchDescriptor<ClipRecord>(
            predicate: #Predicate { record in record.id == id }
        )
        guard let record = try context.fetch(descriptor).first else {
            return
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        var details = try details(from: record)
        details.title = trimmed
        record.encryptedListPayload = try encryptedDetailsPayload(details)
        clearPlaintextDetails(on: record)
        record.updatedAt = Date()
        try context.save()
    }

    public func updateTags(id: String, tags: [String]) throws {
        let descriptor = FetchDescriptor<ClipRecord>(
            predicate: #Predicate { record in record.id == id }
        )
        guard let record = try context.fetch(descriptor).first else {
            return
        }

        var details = try details(from: record)
        details.tags = normalizedTags(tags)
        record.encryptedListPayload = try encryptedDetailsPayload(details)
        clearPlaintextDetails(on: record)
        record.updatedAt = Date()
        try context.save()
    }

    public func saveFolder(_ folder: CollectionFolder, parentID: String?, sortOrder: Int) throws {
        try withFolderRollback {
            try seedDefaultFoldersIfNeeded()
            let records = try context.fetch(FetchDescriptor<FolderRecord>())
            let parent = records.first(where: { $0.id == parentID }).map(folder(from:))
            let validatedFolder = try WorkspaceFolderCreateValidator.validate(
                folder: folder,
                parentID: parentID,
                parent: parent,
                existingIDs: Set(records.map(\.id))
            )
            context.insert(FolderRecord(folder: validatedFolder, parentID: parentID, sortOrder: sortOrder))
            try saveFolderContext(context)
        }
    }

    public func updateFolder(id: String, title: String, parentID: String?) throws {
        try withFolderRollback {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw FolderStoreError.emptyTitle
            }
            guard parentID != id else {
                throw FolderStoreError.invalidMove
            }

            let records = try context.fetch(FetchDescriptor<FolderRecord>())
            guard let record = records.first(where: { $0.id == id }) else {
                throw FolderStoreError.notFound
            }
            guard !isProtectedFolder(record, in: records) else {
                throw FolderStoreError.protectedFolder
            }
            if let parentID {
                guard let parent = records.first(where: { $0.id == parentID }) else {
                    throw FolderStoreError.notFound
                }
                guard parent.collectionID == nil, !isDescendant(parentID, of: id, in: records) else {
                    throw FolderStoreError.invalidMove
                }
            }

            let didMove = record.parentID != parentID
            record.title = trimmed
            record.parentID = parentID
            if didMove {
                record.sortOrder = nextSortOrder(parentID: parentID, in: records)
            }
            try saveFolderContext(context)
        }
    }

    public func deleteFolder(id: String) throws {
        try withFolderRollback {
            let records = try context.fetch(FetchDescriptor<FolderRecord>())
            guard let record = records.first(where: { $0.id == id }) else {
                throw FolderStoreError.notFound
            }

            let recordsToDelete = descendantsAndSelf(of: record, in: records)
            guard recordsToDelete.allSatisfy({ !isProtectedFolder($0, in: records) }) else {
                throw FolderStoreError.protectedFolder
            }

            let removedCollectionIDs = Set(recordsToDelete.compactMap(\.collectionID))
            for recordToDelete in recordsToDelete {
                context.delete(recordToDelete)
            }

            if !removedCollectionIDs.isEmpty {
                let clipRecords = try context.fetch(FetchDescriptor<ClipRecord>())
                for clipRecord in clipRecords {
                    let existingIDs = split(clipRecord.collectionIDsRaw)
                    let updatedIDs = existingIDs.filter { !removedCollectionIDs.contains($0) }
                    guard updatedIDs != existingIDs else {
                        continue
                    }
                    clipRecord.collectionIDsRaw = updatedIDs.joined(separator: ",")
                    clipRecord.updatedAt = Date()
                }
            }

            try saveFolderContext(context)
        }
    }

    public func delete(id: String) throws {
        let descriptor = FetchDescriptor<ClipRecord>(
            predicate: #Predicate { record in record.id == id }
        )
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }

    public func delete(ids: [String]) throws {
        for id in ids {
            try delete(id: id)
        }
    }

    public func pruneExpired(now: Date = Date()) throws {
        for clip in try allClips() where retentionPolicy.shouldExpire(clip, now: now) {
            let descriptor = FetchDescriptor<ClipRecord>(
                predicate: #Predicate { record in record.id == clip.id }
            )
            for record in try context.fetch(descriptor) {
                context.delete(record)
            }
        }
        try context.save()
    }

    private func recordToClip(_ record: ClipRecord) throws -> Clip? {
        let details = try details(from: record)
        let payload = details.listPayload

        return Clip(
            id: record.id,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            kind: ClipKind(rawValue: record.kindRaw) ?? .unknown,
            title: details.title,
            preview: payload.displayText,
            extractedText: payload.extractedText,
            isPinned: record.isPinned,
            collectionIDs: split(record.collectionIDsRaw),
            pinboardIDs: split(record.pinboardIDsRaw),
            sourceApp: details.sourceApp,
            fingerprint: record.fingerprintValue,
            previewData: payload.previewData,
            metadata: payload.metadata,
            userNote: details.userNote,
            tags: details.tags,
            copyCount: record.copyCount ?? 1
        )
    }

    private func seedDefaultFolders() throws {
        try withFolderRollback {
            for (index, folder) in CollectionFolder.defaults.enumerated() {
                insertFolderTree(folder, parentID: nil, sortOrder: index)
            }
            try saveFolderContext(context)
        }
    }

    private func seedDefaultFoldersIfNeeded() throws {
        guard try context.fetch(FetchDescriptor<FolderRecord>()).isEmpty else {
            return
        }
        try seedDefaultFolders()
    }

    private func insertFolderTree(_ folder: CollectionFolder, parentID: String?, sortOrder: Int) {
        context.insert(FolderRecord(folder: folder, parentID: parentID, sortOrder: sortOrder))
        for (index, child) in folder.children.enumerated() {
            insertFolderTree(child, parentID: folder.id, sortOrder: index)
        }
    }

    private func folderTree(from records: [FolderRecord], parentID: String?) -> [CollectionFolder] {
        records
            .filter { $0.parentID == parentID }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.createdAt < $1.createdAt
                }
                return $0.sortOrder < $1.sortOrder
            }
            .map { record in
                CollectionFolder(
                    id: record.id,
                    title: record.title,
                    collectionID: record.collectionID,
                    children: folderTree(from: records, parentID: record.id),
                    createdAt: record.createdAt
                )
            }
    }

    private func folder(from record: FolderRecord) -> CollectionFolder {
        CollectionFolder(
            id: record.id,
            title: record.title,
            collectionID: record.collectionID,
            createdAt: record.createdAt
        )
    }

    private func withFolderRollback<Result>(_ operation: () throws -> Result) throws -> Result {
        do {
            return try operation()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func isProtectedFolder(_ record: FolderRecord, in records: [FolderRecord]) -> Bool {
        WorkspaceFolderPolicy.isProtected(
            collectionID: record.collectionID,
            childCollectionIDs: Set(records.lazy.compactMap { child in
                child.parentID == record.id ? child.collectionID : nil
            })
        )
    }

    private func isDescendant(_ possibleDescendantID: String, of rootID: String, in records: [FolderRecord]) -> Bool {
        for child in records where child.parentID == rootID {
            if child.id == possibleDescendantID || isDescendant(possibleDescendantID, of: child.id, in: records) {
                return true
            }
        }
        return false
    }

    private func descendantsAndSelf(of root: FolderRecord, in records: [FolderRecord]) -> [FolderRecord] {
        let children = records
            .filter { $0.parentID == root.id }
            .flatMap { descendantsAndSelf(of: $0, in: records) }
        return [root] + children
    }

    private func nextSortOrder(parentID: String?, in records: [FolderRecord]) -> Int {
        let siblingOrders = records
            .filter { $0.parentID == parentID }
            .map(\.sortOrder)
        return (siblingOrders.max() ?? -1) + 1
    }

    private func payload(from record: ClipRecord) throws -> ClipPayload {
        let payloadData = try encryptor.decrypt(record.encryptedPayload)
        return try decoder.decode(ClipPayload.self, from: payloadData)
    }

    private func details(from record: ClipRecord) throws -> EncryptedClipDetails {
        if let encryptedListPayload = record.encryptedListPayload {
            let decrypted = try encryptor.decrypt(encryptedListPayload)
            if let details = try? decoder.decode(EncryptedClipDetails.self, from: decrypted) {
                guard details.version == EncryptedClipDetails.currentVersion else {
                    throw EncryptedClipDetailsError.unsupportedVersion(details.version)
                }
                clearPlaintextDetails(on: record)
                return details
            }

            if let legacyListPayload = try? decoder.decode(ClipPayload.self, from: decrypted) {
                return try migrateDetails(for: record, listPayload: legacyListPayload)
            }
        }

        let legacyPayload = try payload(from: record)
        return try migrateDetails(for: record, listPayload: listPayload(for: legacyPayload))
    }

    private func migrateDetails(for record: ClipRecord, listPayload: ClipPayload) throws -> EncryptedClipDetails {
        let details = EncryptedClipDetails(
            listPayload: listPayload,
            title: record.title.isEmpty ? title(for: listPayload) : record.title,
            userNote: record.userNote ?? "",
            tags: split(record.tagsRaw ?? ""),
            sourceApp: record.sourceApp
        )
        record.encryptedListPayload = try encryptedDetailsPayload(details)
        clearPlaintextDetails(on: record)
        return details
    }

    private func encryptedDetailsPayload(_ details: EncryptedClipDetails) throws -> Data {
        try encryptor.encrypt(encoder.encode(details))
    }

    private func clearPlaintextDetails(on record: ClipRecord) {
        record.title = ""
        record.preview = ""
        record.sourceApp = nil
        record.userNote = nil
        record.tagsRaw = nil
    }

    private func listPayload(for payload: ClipPayload) -> ClipPayload {
        ClipPayload(
            kind: payload.kind,
            displayText: payload.displayText,
            extractedText: payload.extractedText,
            metadata: payload.metadata,
            previewData: payload.kind == .image
                ? payload.previewData.flatMap(previewTransformer)
                : nil,
            uniformTypeIdentifiers: payload.uniformTypeIdentifiers
        )
    }

    private func split(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted()
    }

    private func title(for payload: ClipPayload) -> String {
        if payload.kind == .image {
            let lineCount = payload.extractedText
                .split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .count
            return lineCount > 0 ? "Image with \(lineCount) text lines" : "Image"
        }

        let firstLine = payload.displayText
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let firstLine, !firstLine.isEmpty {
            return String(firstLine.prefix(80))
        }
        return payload.kind.title
    }

}

public final class InMemoryClipStore: ClipStoring {
    private var clips: [Clip] = []
    private var payloads: [String: ClipPayload] = [:]
    private var storedFolders: [CollectionFolder] = CollectionFolder.defaults
    private let sensitiveRules: SensitiveRuleEngine
    private let index: any SearchIndexing

    public init(
        sensitiveRules: SensitiveRuleEngine = .default,
        index: any SearchIndexing = RustSearchIndexCore()
    ) {
        self.sensitiveRules = sensitiveRules
        self.index = index
    }

    public func allClips() throws -> [Clip] {
        clips.sorted { $0.createdAt > $1.createdAt }
    }

    public func folders() throws -> [CollectionFolder] {
        storedFolders
    }

    public func payload(for clipID: String) throws -> ClipPayload? {
        payloads[clipID]
    }

    public func save(payload: ClipPayload, sourceApp: String?) throws -> Clip? {
        guard !sensitiveRules.classify(payload.extractedText).isExcluded else {
            return nil
        }
        let fingerprint = index.fingerprint(payload.searchableText)
        if let existingIndex = clips.firstIndex(where: { $0.fingerprint == fingerprint }) {
            clips[existingIndex].copyCount += 1
            clips[existingIndex].updatedAt = Date()
            clips[existingIndex].preview = payload.displayText
            clips[existingIndex].extractedText = payload.extractedText
            clips[existingIndex].previewData = payload.previewData
            clips[existingIndex].metadata = payload.metadata
            payloads[clips[existingIndex].id] = payload
            return clips[existingIndex]
        }

        let clip = Clip(
            kind: payload.kind,
            title: payload.displayText.isEmpty ? payload.kind.title : String(payload.displayText.prefix(80)),
            preview: payload.displayText,
            extractedText: payload.extractedText,
            collectionIDs: BuiltInCollectionAssignment.ids(for: payload.kind),
            sourceApp: sourceApp,
            fingerprint: fingerprint,
            previewData: payload.previewData,
            metadata: payload.metadata
        )
        clips.append(clip)
        payloads[clip.id] = payload
        return clip
    }

    public func addClips(ids: [String], toCollectionID collectionID: String) throws {
        let idSet = Set(ids)
        guard !idSet.isEmpty, !collectionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        for index in clips.indices where idSet.contains(clips[index].id) {
            if !clips[index].collectionIDs.contains(collectionID) {
                clips[index].collectionIDs.append(collectionID)
                clips[index].updatedAt = Date()
            }
        }
    }

    public func togglePinned(id: String) throws {
        guard let index = clips.firstIndex(where: { $0.id == id }) else {
            return
        }
        clips[index].isPinned.toggle()
    }

    public func updateNote(id: String, note: String) throws {
        guard let index = clips.firstIndex(where: { $0.id == id }) else {
            return
        }
        clips[index].userNote = note
        clips[index].updatedAt = Date()
    }

    public func updateTitle(id: String, title: String) throws {
        guard let index = clips.firstIndex(where: { $0.id == id }) else {
            return
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        clips[index].title = trimmed
        clips[index].updatedAt = Date()
    }

    public func updateTags(id: String, tags: [String]) throws {
        guard let index = clips.firstIndex(where: { $0.id == id }) else {
            return
        }
        clips[index].tags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        clips[index].updatedAt = Date()
    }

    public func saveFolder(_ folder: CollectionFolder, parentID: String?, sortOrder: Int) throws {
        let parent = parentID.flatMap { findFolder(id: $0, in: storedFolders) }
        let validatedFolder = try WorkspaceFolderCreateValidator.validate(
            folder: folder,
            parentID: parentID,
            parent: parent,
            existingIDs: Set(allFolders(in: storedFolders).map(\.id))
        )
        guard let parentID else {
            storedFolders.append(validatedFolder)
            return
        }
        guard insert(validatedFolder, under: parentID, in: &storedFolders) else {
            throw FolderStoreError.notFound
        }
    }

    public func updateFolder(id: String, title: String, parentID: String?) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FolderStoreError.emptyTitle
        }
        guard parentID != id else {
            throw FolderStoreError.invalidMove
        }
        guard var folder = findFolder(id: id, in: storedFolders) else {
            throw FolderStoreError.notFound
        }
        guard !isProtectedFolder(folder) else {
            throw FolderStoreError.protectedFolder
        }
        if let parentID {
            guard let parent = findFolder(id: parentID, in: storedFolders) else {
                throw FolderStoreError.notFound
            }
            guard parent.collectionID == nil, !containsFolder(id: parentID, in: [folder]) else {
                throw FolderStoreError.invalidMove
            }
        }
        guard removeFolder(id: id, from: &storedFolders) != nil else {
            throw FolderStoreError.notFound
        }

        folder.title = trimmed
        if let parentID {
            guard insert(folder, under: parentID, in: &storedFolders) else {
                throw FolderStoreError.notFound
            }
        } else {
            storedFolders.append(folder)
        }
    }

    public func deleteFolder(id: String) throws {
        guard let folder = findFolder(id: id, in: storedFolders) else {
            throw FolderStoreError.notFound
        }
        guard allFolders(in: [folder]).allSatisfy({ !isProtectedFolder($0) }) else {
            throw FolderStoreError.protectedFolder
        }
        guard let removed = removeFolder(id: id, from: &storedFolders) else {
            throw FolderStoreError.notFound
        }

        let removedCollectionIDs = Set(allFolders(in: [removed]).compactMap(\.collectionID))
        guard !removedCollectionIDs.isEmpty else {
            return
        }
        for index in clips.indices {
            let originalIDs = clips[index].collectionIDs
            clips[index].collectionIDs.removeAll { removedCollectionIDs.contains($0) }
            guard clips[index].collectionIDs != originalIDs else {
                continue
            }
            clips[index].updatedAt = Date()
        }
    }

    public func delete(id: String) throws {
        clips.removeAll { $0.id == id }
        payloads.removeValue(forKey: id)
    }

    public func delete(ids: [String]) throws {
        for id in ids {
            try delete(id: id)
        }
    }

    public func pruneExpired(now: Date) throws {
        let expiredIDs = clips
            .filter { RetentionPolicy.default.shouldExpire($0, now: now) }
            .map(\.id)
        clips.removeAll { expiredIDs.contains($0.id) }
        for id in expiredIDs {
            payloads.removeValue(forKey: id)
        }
    }

    private func insert(_ folder: CollectionFolder, under parentID: String, in roots: inout [CollectionFolder]) -> Bool {
        for index in roots.indices {
            if roots[index].id == parentID {
                roots[index].children.append(folder)
                return true
            }
            if insert(folder, under: parentID, in: &roots[index].children) {
                return true
            }
        }
        return false
    }

    private func findFolder(id: String, in folders: [CollectionFolder]) -> CollectionFolder? {
        for folder in folders {
            if folder.id == id {
                return folder
            }
            if let nested = findFolder(id: id, in: folder.children) {
                return nested
            }
        }
        return nil
    }

    private func containsFolder(id: String, in folders: [CollectionFolder]) -> Bool {
        findFolder(id: id, in: folders) != nil
    }

    private func removeFolder(id: String, from folders: inout [CollectionFolder]) -> CollectionFolder? {
        for index in folders.indices {
            if folders[index].id == id {
                return folders.remove(at: index)
            }
            if let removed = removeFolder(id: id, from: &folders[index].children) {
                return removed
            }
        }
        return nil
    }

    private func allFolders(in folders: [CollectionFolder]) -> [CollectionFolder] {
        folders.flatMap { folder in
            [folder] + allFolders(in: folder.children)
        }
    }

    private func isProtectedFolder(_ folder: CollectionFolder) -> Bool {
        WorkspaceFolderPolicy.isProtected(folder)
    }
}
