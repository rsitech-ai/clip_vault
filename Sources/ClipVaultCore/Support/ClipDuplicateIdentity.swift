import CryptoKit
import Foundation

/// Fingerprints narrow the lookup; payload comparison decides whether replacement is safe.
struct ClipDuplicateIdentity {
    let fingerprint: UInt64
    let legacyFingerprint: UInt64
    private let payload: ClipPayload
    private let index: any SearchIndexing

    init(payload: ClipPayload, index: any SearchIndexing) {
        self.payload = payload
        self.index = index
        legacyFingerprint = index.fingerprint(payload.searchableText)
        switch payload.kind {
        case .image, .richText:
            let digest = payload.previewData.map { data in
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } ?? "no-binary-data"
            fingerprint = index.fingerprint("\(payload.kind.rawValue):\(digest):\(payload.searchableText)")
        case .file:
            if let id = payload.metadata["file_id"], let origin = payload.metadata["file_origin"] {
                fingerprint = index.fingerprint("attachment:\(origin):\(id)")
                return
            }
            let paths = payload.metadata["paths"] ?? payload.displayText
            let digest = SHA256.hash(data: Data(paths.utf8)).map { String(format: "%02x", $0) }.joined()
            fingerprint = index.fingerprint("file:\(digest)")
        default:
            // Preserve existing text fingerprints, including generated-prompt duplicate checks.
            fingerprint = legacyFingerprint
        }
    }

    func matches(_ candidate: ClipPayload) -> Bool {
        guard candidate.kind == payload.kind else { return false }
        switch payload.kind {
        case .image, .richText:
            guard candidate.previewData == payload.previewData else { return false }
        case .file:
            if payload.metadata["file_id"] != nil || candidate.metadata["file_id"] != nil {
                return candidate.metadata["file_id"] == payload.metadata["file_id"]
                    && candidate.metadata["file_origin"] == payload.metadata["file_origin"]
                    && candidate.metadata["file_sha256"] == payload.metadata["file_sha256"]
            }
            return (candidate.metadata["paths"] ?? candidate.displayText)
                == (payload.metadata["paths"] ?? payload.displayText)
        default:
            break
        }
        return index.normalizedText(candidate.searchableText) == index.normalizedText(payload.searchableText)
    }
}
