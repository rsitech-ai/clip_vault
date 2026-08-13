import Foundation

public enum ClipRowTitleTruncation: Equatable, Sendable {
    case tail
    case middle
}

public struct ClipRowPresentation: Equatable, Sendable {
    public var eyebrow: String?
    public var title: String
    public var preview: String?
    public var metadata: [String]
    public var titleTruncation: ClipRowTitleTruncation
    public var accessibilitySummary: String

    public init(
        clip: Clip,
        locale _: Locale = .autoupdatingCurrent
    ) {
        let link = Self.linkParts(for: clip)
        let derivedTitle = link?.title
            ?? Self.nonempty(clip.title)
            ?? Self.firstMeaningfulLine(in: clip.preview)
            ?? clip.kind.title

        eyebrow = link?.host
        title = derivedTitle
        preview = Self.preview(
            for: clip,
            displayedTitle: derivedTitle,
            linkDisplayURL: link?.displayURL
        )
        metadata = Self.metadata(for: clip)
        titleTruncation = clip.kind == .file ? .middle : .tail
        accessibilitySummary = Self.accessibilitySummary(
            preview: preview,
            metadata: metadata
        )
    }

    private struct LinkParts {
        var host: String
        var title: String
        var displayURL: String
    }

    private static func linkParts(for clip: Clip) -> LinkParts? {
        guard clip.kind == .url,
              let source = nonempty(clip.preview) ?? nonempty(clip.title),
              let components = URLComponents(string: source),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty else {
            return nil
        }

        let host = rawHost.hasPrefix("www.")
            ? String(rawHost.dropFirst(4))
            : rawHost
        let pathParts = components.percentEncodedPath
            .split(separator: "/")
            .map(String.init)
            .map { $0.removingPercentEncoding ?? $0 }
            .filter { !$0.isEmpty }

        let title: String
        if host == "github.com", pathParts.count >= 2 {
            title = pathParts.prefix(2).joined(separator: " / ")
        } else if pathParts.isEmpty {
            title = host
        } else {
            title = pathParts.suffix(2).joined(separator: " / ")
        }

        return LinkParts(
            host: host,
            title: title,
            displayURL: normalizedWhitespace(source)
        )
    }

    private static func preview(
        for clip: Clip,
        displayedTitle: String,
        linkDisplayURL: String?
    ) -> String? {
        if let linkDisplayURL {
            return duplicateAwarePreview(
                linkDisplayURL,
                displayedTitle: displayedTitle
            )
        }

        let candidates: [String]
        if clip.kind == .image {
            candidates = [clip.extractedText, clip.sourceApp ?? ""]
        } else {
            candidates = [clip.preview, clip.extractedText]
        }

        for candidate in candidates {
            if let value = duplicateAwarePreview(
                candidate,
                displayedTitle: displayedTitle
            ) {
                return value
            }
        }
        return nil
    }

    private static func duplicateAwarePreview(
        _ candidate: String,
        displayedTitle: String
    ) -> String? {
        let lines = candidate
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .compactMap(nonempty)
        let normalizedTitle = normalizedComparison(displayedTitle)

        guard !lines.isEmpty else { return nil }
        if normalizedComparison(lines[0]) == normalizedTitle {
            let remainder = lines.dropFirst().joined(separator: " ")
            return nonempty(remainder)
        }

        let normalized = normalizedWhitespace(lines.joined(separator: " "))
        guard normalizedComparison(normalized) != normalizedTitle else {
            return nil
        }
        return normalized
    }

    private static func metadata(for clip: Clip) -> [String] {
        var values = [clip.kind.title]
        if clip.copyCount > 1 {
            values.append("\(clip.copyCount) copies")
        }
        if clip.isPinned {
            values.append("Pinned")
        }
        if let sourceApp = nonempty(clip.sourceApp ?? "") {
            values.append(sourceApp)
        }
        return values
    }

    private static func accessibilitySummary(
        preview: String?,
        metadata: [String]
    ) -> String {
        var values: [String] = []
        if let preview {
            values.append(String(preview.prefix(300)))
        }
        values.append(contentsOf: metadata)
        return values.joined(separator: ". ")
    }

    private static func firstMeaningfulLine(in value: String) -> String? {
        value
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .compactMap(nonempty)
            .first
    }

    private static func nonempty(_ value: String) -> String? {
        let normalized = normalizedWhitespace(value)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalizedComparison(_ value: String) -> String {
        normalizedWhitespace(value).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
