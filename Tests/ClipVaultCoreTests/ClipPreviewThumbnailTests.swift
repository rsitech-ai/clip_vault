import AppKit
import ImageIO
import SwiftData
import Testing
@testable import ClipVaultCore

@Suite("Clip preview thumbnails")
struct ClipPreviewThumbnailTests {
    @Test("large images become bounded in-memory previews")
    func largeImagesBecomeBoundedPreviews() throws {
        let sourceData = try makeLargeTIFF(width: 2_048, height: 1_536)

        let thumbnailData = try #require(ClipPreviewThumbnailer.thumbnailData(from: sourceData))
        let source = try #require(CGImageSourceCreateWithData(thumbnailData as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)

        #expect(max(width, height) <= ClipPreviewThumbnailer.maximumPixelSize)
        #expect(thumbnailData.count < sourceData.count)
    }

    @Test("persistent clips use previews while payload reads preserve original bytes")
    func persistentStoreSeparatesPreviewFromPayload() throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let configuration = ModelConfiguration(
            "ClipPreviewThumbnailTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let original = Data([1, 2, 3, 4])
        let store = SwiftDataClipStore(
            context: context,
            encryptor: TestPayloadEncryptor(),
            saveContext: { try $0.save() },
            previewTransformer: { _ in Data([9]) }
        )

        let saved = try #require(try store.save(
            payload: ClipPayload(
                kind: .image,
                displayText: "Image",
                extractedText: "",
                previewData: original
            ),
            sourceApp: "Tests"
        ))
        let listed = try #require(try store.allClips().first)
        let payload = try #require(try store.payload(for: saved.id))
        let record = try #require(try context.fetch(FetchDescriptor<ClipRecord>()).first)

        #expect(listed.previewData == Data([9]))
        #expect(payload.previewData == original)
        #expect(record.encryptedListPayload != nil)
    }

    @Test("legacy records gain an encrypted list payload on first read")
    func legacyRecordsMigrateOnRead() throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let configuration = ModelConfiguration(
            "ClipPreviewLegacyTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let original = Data([1, 2, 3, 4])
        let payload = ClipPayload(
            kind: .image,
            displayText: "Legacy image",
            extractedText: "legacy OCR",
            previewData: original
        )
        let encrypted = try TestPayloadEncryptor().encrypt(JSONEncoder().encode(payload))
        let record = ClipRecord(
            clip: Clip(
                kind: .image,
                title: "Legacy image",
                preview: "Legacy image",
                extractedText: "legacy OCR"
            ),
            encryptedPayload: encrypted
        )
        context.insert(record)
        try context.save()

        let store = SwiftDataClipStore(
            context: context,
            encryptor: TestPayloadEncryptor(),
            saveContext: { try $0.save() },
            previewTransformer: { _ in Data([9]) }
        )
        let listed = try #require(try store.allClips().first)

        #expect(listed.previewData == Data([9]))
        #expect(record.encryptedListPayload != nil)
        #expect(try store.payload(for: record.id)?.previewData == original)
    }

    private func makeLargeTIFF(width: Int, height: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try #require(bitmap.tiffRepresentation)
    }
}

private struct TestPayloadEncryptor: PayloadEncrypting {
    func encrypt(_ data: Data) throws -> Data {
        data
    }

    func decrypt(_ data: Data) throws -> Data {
        data
    }
}
