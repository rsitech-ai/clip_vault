import Foundation

@_silgen_name("cv_normalize_text")
private func cv_normalize_text(_ input: UnsafePointer<UInt8>?, _ len: Int) -> UnsafeMutablePointer<CChar>?

@_silgen_name("cv_fingerprint")
private func cv_fingerprint(_ input: UnsafePointer<UInt8>?, _ len: Int) -> UInt64

@_silgen_name("cv_lexical_score")
private func cv_lexical_score(
    _ query: UnsafePointer<UInt8>?,
    _ queryLen: Int,
    _ text: UnsafePointer<UInt8>?,
    _ textLen: Int
) -> Double

@_silgen_name("cv_free_string")
private func cv_free_string(_ value: UnsafeMutablePointer<CChar>?)

public protocol SearchIndexing: Sendable {
    func normalizedText(_ text: String) -> String
    func fingerprint(_ text: String) -> UInt64
    func lexicalScore(query: String, text: String) -> Double
}

public struct RustSearchIndexCore: SearchIndexing {
    public init() {}

    public func normalizedText(_ text: String) -> String {
        withUTF8Bytes(text) { pointer, count in
            guard let raw = cv_normalize_text(pointer, count) else {
                return ""
            }
            defer { cv_free_string(raw) }
            return String(cString: raw)
        }
    }

    public func fingerprint(_ text: String) -> UInt64 {
        withUTF8Bytes(text) { pointer, count in
            cv_fingerprint(pointer, count)
        }
    }

    public func lexicalScore(query: String, text: String) -> Double {
        withUTF8Bytes(query) { queryPointer, queryCount in
            withUTF8Bytes(text) { textPointer, textCount in
                cv_lexical_score(queryPointer, queryCount, textPointer, textCount)
            }
        }
    }

    private func withUTF8Bytes<Result>(
        _ text: String,
        _ body: (UnsafePointer<UInt8>?, Int) -> Result
    ) -> Result {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress, buffer.count)
        }
    }
}

public struct SearchQuery: Hashable, Sendable {
    public var text: String
    public var collectionID: String?

    public init(text: String, collectionID: String? = nil) {
        self.text = text
        self.collectionID = collectionID
    }
}

public struct SearchResult: Identifiable, Hashable, Sendable {
    public var id: String { clip.id }
    public var clip: Clip
    public var score: Double

    public init(clip: Clip, score: Double) {
        self.clip = clip
        self.score = score
    }
}

public struct ClipSearcher: Sendable {
    private let index: any SearchIndexing

    public init(index: any SearchIndexing = RustSearchIndexCore()) {
        self.index = index
    }

    public func search(_ clips: [Clip], query: SearchQuery) -> [SearchResult] {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)

        return clips
            .filter { clip in
                guard let collectionID = query.collectionID, collectionID != "all" else {
                    return true
                }
                return clip.collectionIDs.contains(collectionID)
            }
            .compactMap { clip -> SearchResult? in
                let lexical = trimmed.isEmpty ? 0.2 : index.lexicalScore(query: trimmed, text: clip.searchableContent)
                guard trimmed.isEmpty || lexical > 0 else {
                    return nil
                }
                let pinBoost = clip.isPinned ? 0.08 : 0
                let recencyBoost = max(0, 0.1 - Date().timeIntervalSince(clip.createdAt) / 86_400 * 0.002)
                return SearchResult(clip: clip, score: min(1, lexical + pinBoost + recencyBoost))
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.clip.createdAt > rhs.clip.createdAt
                }
                return lhs.score > rhs.score
            }
    }
}
