#if CLIPVAULT_E2E_PROBE
import Foundation

public struct ClipVaultStoreProbeRequest: Equatable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }

    public static func parse(arguments: [String]) -> Self? {
        guard arguments.count == 3,
              arguments[1] == "--verify-stored-clip" else {
            return nil
        }

        let token = arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return nil
        }
        return Self(token: token)
    }
}
#endif
