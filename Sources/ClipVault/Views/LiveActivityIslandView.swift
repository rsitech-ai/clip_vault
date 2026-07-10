import AppKit
import ClipVaultCore
import SwiftUI

struct LiveActivityIslandView: View {
    var model: ClipVaultViewModel
    private let expandsOnHover: Bool
    private let allowsManualToggle: Bool
    private let openWorkspace: () -> Void
    @State private var isExpanded = false

    init(
        model: ClipVaultViewModel,
        defaultExpanded: Bool = false,
        expandsOnHover: Bool = true,
        allowsManualToggle: Bool = true,
        openWorkspace: @escaping () -> Void = {}
    ) {
        self.model = model
        self.expandsOnHover = expandsOnHover
        self.allowsManualToggle = allowsManualToggle
        self.openWorkspace = openWorkspace
        _isExpanded = State(initialValue: defaultExpanded)
    }

    private var latestClip: Clip? {
        model.clips.first
    }

    private var recentClips: [Clip] {
        Array(model.clips.prefix(4))
    }

    var body: some View {
        VStack(spacing: 10) {
            compactIsland

            if isExpanded {
                expandedPanel
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(maxWidth: isExpanded ? 660 : 500)
        .padding(.horizontal, 14)
        .onHover { hovering in
            guard expandsOnHover else {
                return
            }
            withAnimation(.snappy(duration: 0.22)) {
                isExpanded = hovering
            }
        }
        .onTapGesture {
            guard allowsManualToggle else {
                return
            }
            withAnimation(.snappy(duration: 0.22)) {
                isExpanded.toggle()
            }
        }
        .animation(.snappy(duration: 0.22), value: isExpanded)
        .animation(.snappy(duration: 0.18), value: model.captureStatus)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ClipVault live activity, \(model.captureStatus), \(model.clips.count) clips")
    }

    private var compactIsland: some View {
        HStack(spacing: 12) {
            statusOrb

            VStack(alignment: .leading, spacing: 1) {
                Text(model.isCapturing ? "Capturing" : "Paused")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(compactSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()
                .frame(height: 24)
                .overlay(.secondary.opacity(0.16))

            if let latestClip {
                Image(systemName: icon(for: latestClip.kind))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color(for: latestClip.kind))
                    .frame(width: 22)

                Text(latestClip.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .leading)
            } else {
                Text("Copy anything to start")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text("\(model.clips.count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
                .frame(minWidth: 28)
                .padding(.vertical, 5)
                .clipVaultGlassCapsule(tint: .accentColor.opacity(0.10))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .clipVaultGlassCapsule(
            tint: model.isCapturing ? .green.opacity(0.08) : .orange.opacity(0.08),
            interactive: true
        )
        .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                latestPreview

                VStack(alignment: .leading, spacing: 4) {
                    Text(latestClip?.title ?? "No clip captured yet")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(expandedSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Button {
                    model.toggleCapture()
                    if model.isCaptureConsentDisclosurePresented {
                        openWorkspace()
                    }
                } label: {
                    Label(model.isCapturing ? "Pause" : "Resume", systemImage: model.isCapturing ? "pause.fill" : "play.fill")
                }
                .controlSize(.small)
                .clipVaultGlassButtonStyle(prominent: true)
                .tint(model.isCapturing ? .orange : .green)
                .help(model.isCapturing ? "Pause clipboard capture" : "Resume clipboard capture")
            }

            HStack(spacing: 8) {
                Button {
                    if let latestClip {
                        model.copyToClipboard(latestClip)
                    }
                } label: {
                    Label("Copy latest", systemImage: "doc.on.doc")
                }
                .disabled(latestClip == nil)

                Button {
                    if let latestClip {
                        model.selectedClipID = latestClip.id
                        openWorkspace()
                    }
                } label: {
                    Label("Show", systemImage: "arrow.right.circle")
                }
                .disabled(latestClip == nil)

                Button {
                    model.captureInteractiveScreenshot()
                } label: {
                    Label("Screenshot", systemImage: "camera.viewfinder")
                }

                Spacer()
            }
            .clipVaultGlassButtonStyle()
            .controlSize(.small)

            if !recentClips.isEmpty {
                HStack(spacing: 7) {
                    ForEach(recentClips) { clip in
                        Button {
                            model.copyToClipboard(clip)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: icon(for: clip.kind))
                                    .foregroundStyle(color(for: clip.kind))
                                Text(clip.title)
                                    .lineLimit(1)
                            }
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: 130)
                            .clipVaultGlassCapsule(interactive: true)
                        }
                        .buttonStyle(.plain)
                        .help("Copy \(clip.title)")
                    }
                }
            }
        }
        .padding(14)
        .clipVaultGlassSurface(
            cornerRadius: 18,
            tint: model.isCapturing ? .green.opacity(0.08) : .orange.opacity(0.08),
            interactive: true
        )
        .shadow(color: .black.opacity(0.16), radius: 24, y: 14)
    }

    private var statusOrb: some View {
        ZStack {
            Circle()
                .fill(model.isCapturing ? Color.green.opacity(0.22) : Color.orange.opacity(0.2))
                .frame(width: 28, height: 28)
                .scaleEffect(model.isCapturing ? 1.08 : 0.96)
                .opacity(model.isCapturing ? 0.62 : 0.9)

            Circle()
                .fill(model.isCapturing ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
        }
        .frame(width: 30, height: 30)
    }

    @ViewBuilder
    private var latestPreview: some View {
        if let latestClip,
           latestClip.kind == .image,
           let data = latestClip.previewData {
            CachedClipImageView(
                data: data,
                cacheKey: latestClip.previewImageCacheKey,
                contentMode: .fill,
                placeholderSystemImage: "photo"
            )
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill((latestClip.map { color(for: $0.kind) } ?? .white).opacity(0.18))
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: latestClip.map { icon(for: $0.kind) } ?? "doc.on.clipboard")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(latestClip.map { color(for: $0.kind) } ?? .white)
                }
        }
    }

    private var compactSubtitle: String {
        let countText = model.clips.count == 1 ? "1 clip indexed" : "\(model.clips.count) clips indexed"
        if model.captureStatus.localizedCaseInsensitiveContains("clips indexed") {
            return countText
        }
        return "\(countText) • \(model.captureStatus)"
    }

    private var expandedSubtitle: String {
        guard let latestClip else {
            return model.captureStatus
        }

        let source = latestClip.sourceApp ?? latestClip.kind.title
        let copies = latestClip.copyCount > 1 ? " • copied \(latestClip.copyCount)x" : ""
        return "\(source) • \(latestClip.createdAt.formatted(date: .omitted, time: .shortened))\(copies) • \(model.captureStatus)"
    }

    private func icon(for kind: ClipKind) -> String {
        switch kind {
        case .text: "doc.text"
        case .code: "curlybraces"
        case .sql: "tablecells"
        case .url: "link"
        case .richText: "text.append"
        case .image: "photo"
        case .file: "folder"
        case .error: "exclamationmark.triangle"
        case .unknown: "doc.on.clipboard"
        }
    }

    private func color(for kind: ClipKind) -> Color {
        switch kind {
        case .text: .primary
        case .code: .green
        case .sql: .orange
        case .url: .cyan
        case .richText: .pink
        case .image: .purple
        case .file: .mint
        case .error: .red
        case .unknown: .secondary
        }
    }
}
