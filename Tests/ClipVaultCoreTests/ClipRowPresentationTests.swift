import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Clip row presentation")
struct ClipRowPresentationTests {
    @Test("GitHub links expose host and owner repository")
    func githubRepositoryLink() {
        let clip = makeClip(
            kind: .url,
            title: "https://github.com/rsitech-ai/condor",
            preview: "https://github.com/rsitech-ai/condor"
        )

        let value = ClipRowPresentation(
            clip: clip,
            locale: Locale(identifier: "en_US_POSIX")
        )

        #expect(value.eyebrow == "github.com")
        #expect(value.title == "rsitech-ai / condor")
        #expect(value.preview == "https://github.com/rsitech-ai/condor")
        #expect(value.titleTruncation == .tail)
    }

    @Test("Root and malformed links fall back without mutation")
    func linkFallbacks() {
        let root = makeClip(
            kind: .url,
            title: "https://www.example.com/",
            preview: "https://www.example.com/"
        )
        let malformed = makeClip(
            kind: .url,
            title: "not a valid URL",
            preview: "not a valid URL"
        )

        #expect(ClipRowPresentation(clip: root).eyebrow == "example.com")
        #expect(ClipRowPresentation(clip: root).title == "example.com")
        #expect(ClipRowPresentation(clip: malformed).eyebrow == nil)
        #expect(ClipRowPresentation(clip: malformed).title == "not a valid URL")
    }

    @Test("Link queries never become row titles")
    func linkQueryIsNotPromoted() {
        let clip = makeClip(
            kind: .url,
            title: "https://example.com/reset?token=secret-value",
            preview: "https://example.com/reset?token=secret-value"
        )

        let value = ClipRowPresentation(clip: clip)

        #expect(value.eyebrow == "example.com")
        #expect(value.title == "reset")
        #expect(!value.title.contains("secret-value"))
    }

    @Test("Duplicate title preview is omitted")
    func duplicatePreview() {
        let clip = makeClip(
            kind: .text,
            title: "previous clipboard",
            preview: " previous   clipboard "
        )

        #expect(ClipRowPresentation(clip: clip).preview == nil)
    }

    @Test("Text excerpt skips the displayed title line")
    func textExcerpt() {
        let clip = makeClip(
            kind: .text,
            title: "Edited agent handoff",
            preview: "Edited agent handoff\nReview the exact verified state."
        )

        #expect(
            ClipRowPresentation(clip: clip).preview
                == "Review the exact verified state."
        )
    }

    @Test("Relevant metadata is explicit")
    func metadata() {
        let clip = makeClip(
            kind: .code,
            title: "Build",
            preview: "swift build",
            isPinned: true,
            sourceApp: "Terminal",
            copyCount: 302
        )

        #expect(
            ClipRowPresentation(clip: clip).metadata
                == ["Code", "302 copies", "Pinned", "Terminal"]
        )
    }

    @Test("File titles use middle truncation")
    func fileTruncation() {
        let clip = makeClip(
            kind: .file,
            title: "Report.pdf",
            preview: "/Users/example/Documents/Report.pdf"
        )

        #expect(ClipRowPresentation(clip: clip).titleTruncation == .middle)
    }

    @Test("Images prefer OCR preview then source app")
    func imagePreviewFallbacks() {
        let ocr = makeClip(
            kind: .image,
            title: "Screenshot",
            preview: "Screenshot",
            extractedText: "Build completed successfully",
            sourceApp: "Finder"
        )
        let source = makeClip(
            kind: .image,
            title: "Screenshot",
            preview: "Screenshot",
            sourceApp: "Finder"
        )

        #expect(ClipRowPresentation(clip: ocr).preview == "Build completed successfully")
        #expect(ClipRowPresentation(clip: source).preview == "Finder")
    }

    @Test("Accessibility preview is bounded")
    func boundedAccessibility() {
        let clip = makeClip(
            kind: .text,
            title: "Long",
            preview: String(repeating: "a", count: 500)
        )

        let value = ClipRowPresentation(clip: clip)

        #expect(value.accessibilitySummary.count < 380)
        #expect(value.accessibilitySummary.contains("Text"))
    }

    private func makeClip(
        kind: ClipKind,
        title: String,
        preview: String,
        extractedText: String = "",
        isPinned: Bool = false,
        sourceApp: String? = nil,
        copyCount: Int = 1
    ) -> Clip {
        Clip(
            kind: kind,
            title: title,
            preview: preview,
            extractedText: extractedText,
            isPinned: isPinned,
            sourceApp: sourceApp,
            copyCount: copyCount
        )
    }
}
