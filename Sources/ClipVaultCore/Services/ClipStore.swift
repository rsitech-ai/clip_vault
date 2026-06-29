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

    public init(clip: Clip, encryptedPayload: Data) {
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
    }
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
    func delete(id: String) throws
    func delete(ids: [String]) throws
    func pruneExpired(now: Date) throws
}

public final class SwiftDataClipStore: ClipStoring {
    private let context: ModelContext
    private let encryptor: any PayloadEncrypting
    private let sensitiveRules: SensitiveRuleEngine
    private let index: any SearchIndexing
    private let retentionPolicy: RetentionPolicy
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
    }

    public func allClips() throws -> [Clip] {
        let descriptor = FetchDescriptor<ClipRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap(recordToClip)
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
            existing.copyCount = (existing.copyCount ?? 1) + 1
            existing.updatedAt = Date()
            existing.preview = payload.displayText
            let data = try encoder.encode(payload)
            existing.encryptedPayload = try encryptor.encrypt(data)
            try context.save()
            return try recordToClip(existing)
        }

        let clip = Clip(
            kind: payload.kind,
            title: title(for: payload),
            preview: payload.displayText,
            extractedText: payload.extractedText,
            collectionIDs: collectionIDs(for: payload),
            sourceApp: sourceApp,
            fingerprint: fingerprint,
            previewData: payload.previewData,
            metadata: payload.metadata
        )

        let data = try encoder.encode(payload)
        let encrypted = try encryptor.encrypt(data)
        context.insert(ClipRecord(clip: clip, encryptedPayload: encrypted))
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

        record.userNote = note
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
        record.title = trimmed
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

        record.tagsRaw = normalizedTags(tags).joined(separator: ",")
        record.updatedAt = Date()
        try context.save()
    }

    public func saveFolder(_ folder: CollectionFolder, parentID: String?, sortOrder: Int) throws {
        context.insert(FolderRecord(folder: folder, parentID: parentID, sortOrder: sortOrder))
        try context.save()
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
        let payload = try payload(from: record)

        return Clip(
            id: record.id,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            kind: ClipKind(rawValue: record.kindRaw) ?? .unknown,
            title: record.title,
            preview: record.preview,
            extractedText: payload.extractedText,
            isPinned: record.isPinned,
            collectionIDs: split(record.collectionIDsRaw),
            pinboardIDs: split(record.pinboardIDsRaw),
            sourceApp: record.sourceApp,
            fingerprint: record.fingerprintValue,
            previewData: payload.previewData,
            metadata: payload.metadata,
            userNote: record.userNote ?? "",
            tags: split(record.tagsRaw ?? ""),
            copyCount: record.copyCount ?? 1
        )
    }

    private func seedDefaultFolders() throws {
        for (index, folder) in CollectionFolder.defaults.enumerated() {
            try saveFolderTree(folder, parentID: nil, sortOrder: index)
        }
    }

    private func saveFolderTree(_ folder: CollectionFolder, parentID: String?, sortOrder: Int) throws {
        context.insert(FolderRecord(folder: folder, parentID: parentID, sortOrder: sortOrder))
        for (index, child) in folder.children.enumerated() {
            try saveFolderTree(child, parentID: folder.id, sortOrder: index)
        }
        try context.save()
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

    private func payload(from record: ClipRecord) throws -> ClipPayload {
        let payloadData = try encryptor.decrypt(record.encryptedPayload)
        return try decoder.decode(ClipPayload.self, from: payloadData)
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

    private func collectionIDs(for payload: ClipPayload) -> [String] {
        switch payload.kind {
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
            payloads[clips[existingIndex].id] = payload
            return clips[existingIndex]
        }

        let clip = Clip(
            kind: payload.kind,
            title: payload.displayText.isEmpty ? payload.kind.title : String(payload.displayText.prefix(80)),
            preview: payload.displayText,
            extractedText: payload.extractedText,
            collectionIDs: [payload.kind.rawValue],
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
        guard let parentID else {
            storedFolders.append(folder)
            return
        }
        storedFolders = storedFolders.map { insert(folder, under: parentID, in: $0) }
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

    private func insert(_ folder: CollectionFolder, under parentID: String, in root: CollectionFolder) -> CollectionFolder {
        var copy = root
        if copy.id == parentID {
            copy.children.append(folder)
            return copy
        }
        copy.children = copy.children.map { insert(folder, under: parentID, in: $0) }
        return copy
    }
}
