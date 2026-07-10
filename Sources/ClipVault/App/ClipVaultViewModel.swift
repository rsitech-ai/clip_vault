import ClipVaultCore
import Foundation
import Observation
import OSLog
import SwiftData

@MainActor
@Observable
final class ClipVaultViewModel {
    private static let logger = Logger(subsystem: "com.andrzej.ClipVault", category: "ViewModel")

    let container: ModelContainer
    let storageStartupError: String?

    var clips: [Clip] = []
    var collections: [ClipCollection] = ClipCollection.defaults
    var folders: [CollectionFolder] = CollectionFolder.defaults
    var selectedCollectionID = "all" {
        didSet {
            selectFirstVisibleResultIfNeeded()
        }
    }
    var selectedClipID: String?
    var selectedClipIDs: Set<String> = []
    var searchText = "" {
        didSet {
            statusMenuFocusIndex = 0
            selectFirstVisibleResultIfNeeded()
        }
    }
    var isCapturing = false
    var captureStatus = "Ready"
    var aiResult: AIActionResult?
    var aiError: String?
    var isGenerating = false
    var question = ""
    var statusMenuFocusIndex = 0
    var cleanupFilter: CleanupFilter = .unpinned

    var canAskQuestion: Bool {
        !isGenerating && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let captureService = ClipboardCaptureService()
    private let pasteboardWriter = ClipPayloadPasteboardWriter()
    private let searcher = ClipSearcher()
    private let aiProvider: any AIActionProviding = FoundationModelsAIActionProvider()
    private var store: (any ClipStoring)?

    init() {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        do {
            let configuration = ModelConfiguration("ClipVault", schema: schema)
            container = try ModelContainer(for: schema, configurations: [configuration])
            storageStartupError = nil
        } catch {
            storageStartupError = "Persistent storage unavailable: \(error.localizedDescription)"
            let fallback = ModelConfiguration("ClipVaultFallback", schema: schema, isStoredInMemoryOnly: true)
            do {
                container = try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("Could not create ClipVault fallback model container: \(error)")
            }
        }
    }

    func bootstrap() async {
        guard store == nil else {
            return
        }

        Self.logger.info("Bootstrapping ClipVault view model")
        let context = ModelContext(container)
        store = SwiftDataClipStore(context: context)
        captureService.onClipCaptured = { [weak self] payload, sourceApp in
            self?.ingest(payload: payload, sourceApp: sourceApp)
        }
        let screenshotHotKeyRegistered = ScreenshotCaptureController.shared.configure { [weak self] didCapture in
            self?.captureStatus = didCapture ? "Screenshot copied to clipboard" : "Screenshot cancelled"
            self?.updateDockTile()
        }
        captureService.start()
        isCapturing = true
        UserDefaults.standard.set(
            Int(ProcessInfo.processInfo.processIdentifier),
            forKey: ClipVaultSettingsKey.captureReadyProcessID
        )
        captureStatus = screenshotHotKeyRegistered ? "Watching clipboard" : "Watching clipboard, screenshot shortcut unavailable"
        reload()
        pruneExpiredClips(retentionDays: configuredRetentionDays, updatesStatus: false)
        if let storageStartupError {
            Self.logger.error("Persistent storage startup failed; using fallback storage")
            captureStatus = storageStartupError
        }
    }

    var selectedCollection: ClipCollection? {
        collections.first { $0.id == selectedCollectionID }
    }

    var selectedCollectionTitle: String {
        if let selectedCollection {
            return selectedCollection.title
        }
        return folderTitle(forCollectionID: selectedCollectionID, in: folders) ?? "Clips"
    }

    var selectedClip: Clip? {
        clips.first { $0.id == selectedClipID }
    }

    var selectedClips: [Clip] {
        clips.filter { selectedClipIDs.contains($0.id) }
    }

    var visibleResults: [SearchResult] {
        let collection = selectedCollectionID == "all" ? nil : selectedCollectionID
        return searcher.search(
            clips,
            query: SearchQuery(text: searchText, collectionID: collection)
        )
    }

    var aiAvailability: AIAvailability {
        aiProvider.availability()
    }

    func reload() {
        do {
            clips = try store?.allClips() ?? []
            folders = try store?.folders() ?? CollectionFolder.defaults
            syncCollectionsFromFolders()
            captureStatus = clips.isEmpty ? "Ready" : "\(clips.count) clips indexed"
            selectFirstVisibleResultIfNeeded()
        } catch {
            Self.logger.error("Failed to reload clips: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
        }
        updateDockTile()
    }

    var visibleClips: [Clip] {
        visibleResults.map(\.clip)
    }

    var focusedMenuClip: Clip? {
        guard !visibleClips.isEmpty else {
            return nil
        }
        let index = min(max(statusMenuFocusIndex, 0), visibleClips.count - 1)
        return visibleClips[index]
    }

    func toggleCapture() {
        if isCapturing {
            captureService.stop()
            isCapturing = false
            captureStatus = "Paused"
        } else {
            captureService.start()
            isCapturing = true
            captureStatus = "Watching clipboard"
        }
        updateDockTile()
    }

    func togglePinned(_ clip: Clip) {
        do {
            try store?.togglePinned(id: clip.id)
            reload()
        } catch {
            Self.logger.error("Failed to toggle pinned state: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
            updateDockTile()
        }
    }

    func updateNote(for clip: Clip, note: String) {
        do {
            try store?.updateNote(id: clip.id, note: note)
            if let index = clips.firstIndex(where: { $0.id == clip.id }) {
                clips[index].userNote = note
                clips[index].updatedAt = Date()
            }
            captureStatus = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Note cleared" : "Note saved"
            updateDockTile()
        } catch {
            Self.logger.error("Failed to update note: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
            updateDockTile()
        }
    }

    func updateTitle(for clip: Clip, title: String) {
        do {
            try store?.updateTitle(id: clip.id, title: title)
            if let index = clips.firstIndex(where: { $0.id == clip.id }) {
                clips[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                clips[index].updatedAt = Date()
            }
            captureStatus = "Title saved"
            updateDockTile()
        } catch {
            Self.logger.error("Failed to update title: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
            updateDockTile()
        }
    }

    func updateTags(for clip: Clip, tagsText: String) {
        let tags = tagsText
            .split(separator: ",")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            try store?.updateTags(id: clip.id, tags: tags)
            if let index = clips.firstIndex(where: { $0.id == clip.id }) {
                clips[index].tags = Array(Set(tags)).sorted()
                clips[index].updatedAt = Date()
            }
            captureStatus = tags.isEmpty ? "Tags cleared" : "Tags saved"
            updateDockTile()
        } catch {
            Self.logger.error("Failed to update tags: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
            updateDockTile()
        }
    }

    func delete(_ clip: Clip) {
        do {
            try store?.delete(id: clip.id)
            clips.removeAll { $0.id == clip.id }
            selectedClipIDs.remove(clip.id)
            if selectedClipID == clip.id {
                selectedClipID = clips.first?.id
            }
            captureStatus = "Deleted clip"
            updateDockTile()
        } catch {
            Self.logger.error("Failed to delete clip: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
            updateDockTile()
        }
    }

    func clearUnpinnedClips() {
        do {
            let removable = clips.filter { !$0.isPinned }
            for clip in removable {
                try store?.delete(id: clip.id)
            }
            clips.removeAll { !$0.isPinned }
            selectedClipIDs = selectedClipIDs.intersection(Set(clips.map(\.id)))
            if let selectedClipID, !clips.contains(where: { $0.id == selectedClipID }) {
                self.selectedClipID = clips.first?.id
            }
            captureStatus = "Cleared \(removable.count) clips"
            updateDockTile()
        } catch {
            Self.logger.error("Failed to clear unpinned clips: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
            updateDockTile()
        }
    }

    func cleanupCandidates(for filter: CleanupFilter) -> [Clip] {
        let now = Date()
        let duplicateFingerprints = Dictionary(grouping: clips, by: \.fingerprint)
            .filter { $0.value.count > 1 || ($0.value.first?.copyCount ?? 1) > 1 }
            .keys

        switch filter {
        case .images:
            return clips.filter { $0.kind == .image }
        case .old:
            return clips.filter { now.timeIntervalSince($0.createdAt) > 7 * 24 * 60 * 60 && !$0.isPinned }
        case .large:
            return clips.filter { ($0.previewData?.count ?? $0.extractedText.utf8.count) > 350_000 }
        case .unpinned:
            return clips.filter { !$0.isPinned }
        case .noNotes:
            return clips.filter { $0.userNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .duplicates:
            return clips.filter { duplicateFingerprints.contains($0.fingerprint) || $0.copyCount > 1 }
        }
    }

    func deleteCleanupCandidates(for filter: CleanupFilter) {
        let candidates = cleanupCandidates(for: filter)
        do {
            try store?.delete(ids: candidates.map(\.id))
            let ids = Set(candidates.map(\.id))
            clips.removeAll { ids.contains($0.id) }
            selectedClipIDs.subtract(ids)
            if let selectedClipID, ids.contains(selectedClipID) {
                self.selectedClipID = clips.first?.id
            }
            captureStatus = "Deleted \(candidates.count) clips"
            updateDockTile()
        } catch {
            Self.logger.error("Failed to delete cleanup candidates: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
            updateDockTile()
        }
    }

    func pruneExpiredClips(retentionDays: Int) {
        pruneExpiredClips(retentionDays: retentionDays, updatesStatus: true)
    }

    func refreshDockTilePreferences() {
        updateDockTile()
    }

    func refreshLiveNotchPreferences() {
        NotchLiveActivityController.shared.refreshPreferences()
    }

    func captureInteractiveScreenshot() {
        captureStatus = "Select screenshot area"
        updateDockTile()
        ScreenshotCaptureController.shared.captureInteractiveScreenshot()
    }

    func select(_ clip: Clip) {
        selectedClipID = clip.id
        if selectedClipIDs.contains(clip.id) {
            selectedClipIDs.remove(clip.id)
        } else {
            selectedClipIDs.insert(clip.id)
        }
    }

    func selectAndCopy(_ clip: Clip) {
        selectedClipID = clip.id
        copyToClipboard(clip)
    }

    func copyToClipboard(_ clip: Clip) {
        do {
            guard let payload = try store?.payload(for: clip.id) else {
                captureStatus = "Missing payload"
                updateDockTile()
                return
            }
            try pasteboardWriter.write(payload)
            captureService.consumeCurrentPasteboardChange()
            Self.logger.info("Copied clip payload to pasteboard")
            captureStatus = "Copied \(clip.kind.title)"
        } catch {
            Self.logger.error("Failed to copy clip payload: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
        }
        updateDockTile()
    }

    func copyToClipboard(id: String) {
        guard let clip = clips.first(where: { $0.id == id }) else {
            captureStatus = "Clip no longer available"
            updateDockTile()
            return
        }

        selectedClipID = id
        copyToClipboard(clip)
    }

    func moveMenuFocus(_ delta: Int) {
        guard !visibleClips.isEmpty else {
            statusMenuFocusIndex = 0
            return
        }
        statusMenuFocusIndex = min(max(statusMenuFocusIndex + delta, 0), visibleClips.count - 1)
        selectedClipID = visibleClips[statusMenuFocusIndex].id
    }

    func copyFocusedMenuClip() {
        guard let focusedMenuClip else {
            return
        }
        selectAndCopy(focusedMenuClip)
    }

    func deleteFocusedMenuClip() {
        guard let focusedMenuClip else {
            return
        }
        delete(focusedMenuClip)
        statusMenuFocusIndex = min(statusMenuFocusIndex, max(visibleClips.count - 1, 0))
    }

    func togglePinnedFocusedMenuClip() {
        guard let focusedMenuClip else {
            return
        }
        togglePinned(focusedMenuClip)
    }

    func createCollection(title: String, parentFolderID: String?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard canUseAsFolderParent(parentFolderID) else {
            captureStatus = FolderStoreError.invalidMove.localizedDescription
            return
        }

        let id = WorkspaceCollectionID.make(for: trimmed)
        let collection = ClipCollection(id: id, title: trimmed, systemImage: "folder", kind: nil, isSmart: false)
        collections.append(collection)
        let folder = CollectionFolder(title: trimmed, collectionID: id)
        do {
            try store?.saveFolder(folder, parentID: parentFolderID, sortOrder: collections.count)
            insert(folder, under: parentFolderID)
            captureStatus = "Created collection"
        } catch {
            collections.removeAll { $0.id == id }
            Self.logger.error("Failed to create collection: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
        }
        updateDockTile()
    }

    func addSelectedClips(toCollectionID collectionID: String) {
        let ids = selectedClipIDs.isEmpty ? selectedClip.map { [$0.id] } ?? [] : Array(selectedClipIDs)
        guard !ids.isEmpty else {
            captureStatus = "Select clips first"
            return
        }

        do {
            try store?.addClips(ids: ids, toCollectionID: collectionID)
            reload()
            captureStatus = "Added \(ids.count) clips to collection"
            updateDockTile()
        } catch {
            Self.logger.error("Failed to create custom collection assignment: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
            updateDockTile()
        }
    }

    func createFolder(title: String, parentFolderID: String?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard canUseAsFolderParent(parentFolderID) else {
            captureStatus = FolderStoreError.invalidMove.localizedDescription
            return
        }
        let folder = CollectionFolder(title: trimmed)
        do {
            try store?.saveFolder(folder, parentID: parentFolderID, sortOrder: folders.count)
            insert(folder, under: parentFolderID)
            captureStatus = "Created folder"
        } catch {
            Self.logger.error("Failed to create folder: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
        }
        updateDockTile()
    }

    func updateFolder(id: String, title: String, parentFolderID: String?) {
        do {
            try store?.updateFolder(id: id, title: title, parentID: parentFolderID)
            reload()
            captureStatus = "Updated workspace item"
        } catch {
            Self.logger.error("Failed to update folder: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
            updateDockTile()
        }
    }

    func deleteFolder(_ folder: CollectionFolder) {
        do {
            let removedCollectionIDs = Set(flatten([folder]).compactMap(\.collectionID))
            try store?.deleteFolder(id: folder.id)
            if removedCollectionIDs.contains(selectedCollectionID) {
                selectedCollectionID = "all"
            }
            selectedClipIDs.removeAll()
            reload()
            captureStatus = folder.collectionID == nil ? "Removed folder" : "Removed collection"
        } catch {
            Self.logger.error("Failed to delete folder: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
            updateDockTile()
        }
    }

    func canManageWorkspaceFolder(_ folder: CollectionFolder) -> Bool {
        !isProtectedWorkspaceFolder(folder)
    }

    func parentFolderID(for folderID: String) -> String? {
        parentFolderID(for: folderID, in: folders)
    }

    func folderParentOptions(excluding folderID: String? = nil) -> [FolderParentOption] {
        let excludedIDs: Set<String>
        if let folderID, let folder = findFolder(withID: folderID, in: folders) {
            excludedIDs = Set(flatten([folder]).map(\.id))
        } else {
            excludedIDs = []
        }

        let folderOnlyOptions = flatten(folders)
            .filter { $0.collectionID == nil }
            .filter { !excludedIDs.contains($0.id) }
            .map { folder in
                FolderParentOption(
                    folderID: folder.id,
                    title: folder.path(in: folderRoot(containing: folder.id) ?? folder) ?? folder.title
                )
            }

        return [FolderParentOption.root] + folderOnlyOptions
    }

    func runAIAction(_ kind: AIActionKind) {
        let selection = selectedClips.isEmpty ? selectedClip.map { [$0] } ?? [] : selectedClips
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else {
            aiResult = nil
            aiError = AIActionError.emptySelection.localizedDescription
            return
        }
        if kind == .ask, trimmedQuestion.isEmpty {
            aiResult = nil
            aiError = AIActionError.emptyQuestion.localizedDescription
            return
        }

        let request = AIActionRequest(kind: kind, clips: selection, question: trimmedQuestion)
        let provider = aiProvider
        isGenerating = true
        aiError = nil
        aiResult = nil

        Task {
            do {
                let result = try await provider.perform(request)
                await MainActor.run {
                    aiResult = result
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    Self.logger.error("AI action failed: \(error.localizedDescription, privacy: .public)")
                    aiError = error.localizedDescription
                    isGenerating = false
                }
            }
        }
    }

    private func ingest(payload: ClipPayload, sourceApp: String?) {
        do {
            if let clip = try store?.save(payload: payload, sourceApp: sourceApp) {
                if let existingIndex = clips.firstIndex(where: { $0.id == clip.id }) {
                    clips[existingIndex] = clip
                } else {
                    clips.insert(clip, at: 0)
                }
                selectedClipID = clip.id
                Self.logger.info("Captured clipboard item")
                captureStatus = "Added to \(payload.kind.title)"
            } else {
                Self.logger.info("Excluded sensitive clipboard item before persistence")
                captureStatus = "Excluded sensitive item"
            }
            reload()
        } catch {
            Self.logger.error("Failed to ingest clipboard item: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
            updateDockTile()
        }
    }

    private func updateDockTile() {
        DockTileController.shared.update(
            clips: clips,
            isCapturing: isCapturing,
            captureStatus: captureStatus
        )
    }

    private var configuredRetentionDays: Int {
        let value = UserDefaults.standard.integer(
            forKey: ClipVaultSettingsKey.ordinaryClipRetentionDays,
            default: ClipVaultSettingsDefault.ordinaryClipRetentionDays
        )
        return min(max(value, 7), 180)
    }

    private func pruneExpiredClips(retentionDays: Int, updatesStatus: Bool) {
        let policy = RetentionPolicy(ordinaryClipLifetimeDays: min(max(retentionDays, 7), 180))
        let expired = clips.filter { policy.shouldExpire($0) }
        guard !expired.isEmpty else {
            if updatesStatus {
                captureStatus = "No expired clips"
                updateDockTile()
            }
            return
        }

        do {
            let expiredIDs = Set(expired.map(\.id))
            try store?.delete(ids: Array(expiredIDs))
            clips.removeAll { expiredIDs.contains($0.id) }
            selectedClipIDs.subtract(expiredIDs)
            selectFirstVisibleResultIfNeeded()
            if updatesStatus {
                captureStatus = "Removed \(expired.count) expired clips"
            }
        } catch {
            Self.logger.error("Failed to prune expired clips: \(error.localizedDescription, privacy: .public)")
            captureStatus = error.localizedDescription
        }
        updateDockTile()
    }

    private func selectFirstVisibleResultIfNeeded() {
        if let selectedClipID,
           visibleResults.contains(where: { $0.clip.id == selectedClipID }) {
            return
        }

        selectedClipID = visibleResults.first?.clip.id
    }

    private func insert(_ folder: CollectionFolder, under parentFolderID: String?) {
        guard let parentFolderID else {
            folders.append(folder)
            return
        }

        folders = folders.map { existing in
            inserting(folder, under: parentFolderID, in: existing)
        }
    }

    private func inserting(_ folder: CollectionFolder, under parentID: String, in root: CollectionFolder) -> CollectionFolder {
        var copy = root
        if copy.id == parentID {
            copy.children.append(folder)
            return copy
        }
        copy.children = copy.children.map { inserting(folder, under: parentID, in: $0) }
        return copy
    }

    private func syncCollectionsFromFolders() {
        collections = WorkspaceCollectionCatalog.rebuild(from: folders)
    }

    private func folderTitle(forCollectionID collectionID: String, in folders: [CollectionFolder]) -> String? {
        for folder in folders {
            if folder.collectionID == collectionID {
                return folder.title
            }
            if let title = folderTitle(forCollectionID: collectionID, in: folder.children) {
                return title
            }
        }
        return nil
    }

    private func flatten(_ folders: [CollectionFolder]) -> [CollectionFolder] {
        folders.flatMap { folder in
            [folder] + flatten(folder.children)
        }
    }

    private func parentFolderID(for targetID: String, in folders: [CollectionFolder]) -> String? {
        for folder in folders {
            if folder.children.contains(where: { $0.id == targetID }) {
                return folder.id
            }
            if let nested = parentFolderID(for: targetID, in: folder.children) {
                return nested
            }
        }
        return nil
    }

    private func findFolder(withID targetID: String, in folders: [CollectionFolder]) -> CollectionFolder? {
        for folder in folders {
            if folder.id == targetID {
                return folder
            }
            if let nested = findFolder(withID: targetID, in: folder.children) {
                return nested
            }
        }
        return nil
    }

    private func folderRoot(containing targetID: String) -> CollectionFolder? {
        folders.first { folder in
            folder.id == targetID || findFolder(withID: targetID, in: folder.children) != nil
        }
    }

    private func canUseAsFolderParent(_ parentFolderID: String?) -> Bool {
        guard let parentFolderID else {
            return true
        }
        return findFolder(withID: parentFolderID, in: folders)?.collectionID == nil
    }

    private func isProtectedWorkspaceFolder(_ folder: CollectionFolder) -> Bool {
        WorkspaceFolderPolicy.isProtected(folder)
    }
}

struct FolderParentOption: Identifiable, Hashable {
    static let rootID = "__root__"
    static let root = FolderParentOption(folderID: nil, title: "Workspace root")

    var folderID: String?
    var title: String

    var id: String {
        folderID ?? Self.rootID
    }
}

enum CleanupFilter: String, CaseIterable, Identifiable {
    case images = "Images"
    case old = "Older than 7 days"
    case large = "Large clips"
    case unpinned = "Unpinned"
    case noNotes = "No notes"
    case duplicates = "Duplicates"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .images: "photo"
        case .old: "clock.arrow.circlepath"
        case .large: "externaldrive"
        case .unpinned: "pin.slash"
        case .noNotes: "note.text"
        case .duplicates: "square.on.square"
        }
    }
}
