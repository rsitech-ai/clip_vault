import CoreTransferable
import Foundation
import UniformTypeIdentifiers

public struct ClipMovePayload: Codable, Hashable, Sendable, Transferable {
    public static let contentType = UTType(exportedAs: "com.andrzej.ClipVault.clip-move")

    public let clipID: String

    public init?(clipID: String) {
        guard let validated = Self.validated(clipID) else { return nil }
        self.clipID = validated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let clipID = try container.decode(String.self, forKey: .clipID)
        guard let validated = Self.validated(clipID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .clipID,
                in: container,
                debugDescription: "Clip ID is malformed."
            )
        }
        self.clipID = validated
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }

    private static func validated(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(value.utf8.count) else { return nil }

        let allowedPunctuation: Set<UInt8> = [45, 46, 95]
        guard value.utf8.allSatisfy({ byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || allowedPunctuation.contains(byte)
        }) else { return nil }

        return value
    }
}
