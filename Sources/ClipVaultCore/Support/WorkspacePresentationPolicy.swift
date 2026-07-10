public enum WorkspaceWidthClass: Equatable, Sendable {
    case compact
    case regular

    public init(width: Double) {
        self = width < 1_040 ? .compact : .regular
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
