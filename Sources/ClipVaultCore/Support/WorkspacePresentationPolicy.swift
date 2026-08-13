public struct WorkspaceReloadSnapshot: Sendable {
    public var clips: [Clip]
    public var folders: [CollectionFolder]

    public init(clips: [Clip], folders: [CollectionFolder]) {
        self.clips = clips
        self.folders = folders
    }

    public static func load(from store: any ClipStoring) throws -> WorkspaceReloadSnapshot {
        let folders = try store.folders()
        let clips = try store.allClips()
        return WorkspaceReloadSnapshot(clips: clips, folders: folders)
    }
}

public enum MenuBarPresentationPolicy {
    public static let title = "All Clips"

    public static func searchQuery(
        text: String,
        workspaceCollectionID _: String
    ) -> SearchQuery {
        SearchQuery(text: text, collectionID: nil)
    }
}

public enum WorkspaceClipSelectionPolicy {
    public static func reconciledSelection(
        currentID: String?,
        currentIsVisible: Bool,
        firstVisibleID: String?
    ) -> String? {
        if let currentID, currentIsVisible {
            return currentID
        }
        return firstVisibleID
    }
}

public enum WorkspaceWidthClass: Equatable, Sendable {
    case compact
    case regular

    public init(width: Double) {
        self = width < 900 ? .compact : .regular
    }
}

public enum WorkspaceSidebarState: Equatable, Sendable {
    case all
    case contentAndDetail
}

public enum WorkspaceBrowserVisibility: Equatable, Sendable {
    case all
    case contentAndDetail
    case detailOnly
}

public struct WorkspaceFocusState: Equatable, Sendable {
    public private(set) var isFocused = false
    private var restoreVisibility: WorkspaceBrowserVisibility = .all

    public init() {}

    public mutating func enterFocus(
        from visibility: WorkspaceBrowserVisibility
    ) -> WorkspaceBrowserVisibility {
        if visibility != .detailOnly {
            restoreVisibility = visibility
        }
        isFocused = true
        return .detailOnly
    }

    public mutating func restore() -> WorkspaceBrowserVisibility {
        isFocused = false
        return restoreVisibility
    }

    public mutating func recordManualVisibilityChange(
        _ visibility: WorkspaceBrowserVisibility
    ) {
        guard visibility != .detailOnly else {
            return
        }
        restoreVisibility = visibility
        isFocused = false
    }
}

public enum AICommandBarLayout: Equatable, Sendable {
    case compact
    case expanded

    public init(width: Double) {
        self = width < 420 ? .compact : .expanded
    }
}

public struct WorkspaceSidebarAdaptation: Equatable, Sendable {
    public private(set) var isAutomaticallyCollapsed = false

    public init() {}

    public mutating func update(
        width: Double,
        current: WorkspaceSidebarState
    ) -> WorkspaceSidebarState? {
        switch WorkspaceWidthClass(width: width) {
        case .compact:
            guard current == .all else {
                return nil
            }
            isAutomaticallyCollapsed = true
            return .contentAndDetail
        case .regular:
            guard isAutomaticallyCollapsed else {
                return nil
            }
            isAutomaticallyCollapsed = false
            return current == .contentAndDetail ? .all : nil
        }
    }

    public mutating func recordManualVisibilityChange() {
        isAutomaticallyCollapsed = false
    }
}

public enum ClipSelectionMode: Equatable, Sendable {
    case browsing
    case selecting

    public var showsSelectionControls: Bool {
        self == .selecting
    }

    public var headerActionTitle: String {
        switch self {
        case .browsing: "Select Clips"
        case .selecting: "Done"
        }
    }
}

public enum WorkspaceManualDestinationPolicy {
    public static func collectionID(
        for folder: CollectionFolder,
        collections: [ClipCollection]
    ) -> String? {
        guard let rawCollectionID = folder.collectionID else {
            return nil
        }
        let collectionID = rawCollectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collectionID.isEmpty,
              collections.contains(where: { collection in
            collection.id == collectionID && !collection.isSmart
        }) else {
            return nil
        }
        return collectionID
    }
}
