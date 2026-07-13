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

public enum AIWorkspaceDisclosurePolicy {
    public static func shouldExpand(
        previousSelectionCount: Int,
        selectionCount: Int
    ) -> Bool {
        previousSelectionCount == 0 && selectionCount > 0
    }

    public static func shouldExpandForGeneration(isGenerating: Bool) -> Bool {
        isGenerating
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

public struct AIWorkspaceLayoutMetrics: Equatable, Sendable {
    public var detailMinimum: Double
    public var aiMinimum: Double
    public var dividerAllowance: Double

    public init(
        detailMinimum: Double,
        aiMinimum: Double,
        dividerAllowance: Double
    ) {
        self.detailMinimum = detailMinimum
        self.aiMinimum = aiMinimum
        self.dividerAllowance = dividerAllowance
    }
}

public enum AIWorkspaceLayoutPolicy {
    private static let detailFloor = 150.0
    private static let aiFloor = 210.0
    private static let detailPreferred = 280.0
    private static let aiPreferred = 320.0
    private static let dividerAllowance = 8.0

    public static func metrics(availableHeight: Double) -> AIWorkspaceLayoutMetrics {
        let availableContent = max(0, availableHeight - dividerAllowance)
        let preferredTotal = detailPreferred + aiPreferred
        if availableContent >= preferredTotal {
            return AIWorkspaceLayoutMetrics(
                detailMinimum: detailPreferred,
                aiMinimum: aiPreferred,
                dividerAllowance: dividerAllowance
            )
        }

        let floorTotal = detailFloor + aiFloor
        guard availableContent >= floorTotal else {
            let scale = availableContent / floorTotal
            return AIWorkspaceLayoutMetrics(
                detailMinimum: detailFloor * scale,
                aiMinimum: aiFloor * scale,
                dividerAllowance: dividerAllowance
            )
        }

        let remaining = availableContent - floorTotal
        return AIWorkspaceLayoutMetrics(
            detailMinimum: detailFloor + remaining * 0.42,
            aiMinimum: aiFloor + remaining * 0.58,
            dividerAllowance: dividerAllowance
        )
    }
}
