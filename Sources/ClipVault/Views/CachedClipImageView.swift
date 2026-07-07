import AppKit
import ClipVaultCore
import SwiftUI

struct CachedClipImageView: View {
    var data: Data
    var cacheKey: String
    var contentMode: ContentMode
    var placeholderSystemImage: String

    @State private var loadedKey: String?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    Image(systemName: placeholderSystemImage)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: loadImageIfNeeded)
        .onChange(of: cacheKey) {
            loadedKey = nil
            loadImageIfNeeded()
        }
    }

    private func loadImageIfNeeded() {
        guard loadedKey != cacheKey else {
            return
        }

        loadedKey = cacheKey
        image = ClipImageCache.shared.image(forKey: cacheKey, data: data)
    }
}

@MainActor
private final class ClipImageCache {
    static let shared = ClipImageCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func image(forKey key: String, data: Data) -> NSImage? {
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        guard let image = NSImage(data: data) else {
            return nil
        }

        cache.setObject(image, forKey: cacheKey, cost: data.count)
        return image
    }
}

extension Clip {
    var previewImageCacheKey: String {
        "\(id)-\(Int(updatedAt.timeIntervalSinceReferenceDate * 1000))-\(previewData?.count ?? 0)"
    }
}
