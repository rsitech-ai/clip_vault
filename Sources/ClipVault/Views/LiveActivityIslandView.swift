import AppKit
import ClipVaultCore
import SwiftUI

struct LiveActivityIslandView: View {
    var model: ClipVaultViewModel
    private let expandsOnHover: Bool
    private let allowsManualToggle: Bool
    @State private var isExpanded = false
    @State private var pulse = false

    init(
        model: ClipVaultViewModel,
        defaultExpanded: Bool = false,
        expandsOnHover: Bool = true,
        allowsManualToggle: Bool = true
    ) {
        self.model = model
        self.expandsOnHover = expandsOnHover
        self.allowsManualToggle = allowsManualToggle
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
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
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
                    .foregroundStyle(.white)
                Text(compactSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }

            Divider()
                .frame(height: 24)
                .overlay(.white.opacity(0.16))

            if let latestClip {
                Image(systemName: icon(for: latestClip.kind))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color(for: latestClip.kind))
                    .frame(width: 22)

                Text(latestClip.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .leading)
            } else {
                Text("Copy anything to start")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text("\(model.clips.count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: 28)
                .padding(.vertical, 5)
                .background(.white.opacity(0.13), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(islandBackground, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(islandStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                latestPreview

                VStack(alignment: .leading, spacing: 4) {
                    Text(latestClip?.title ?? "No clip captured yet")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(expandedSubtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Button {
                    model.toggleCapture()
                } label: {
                    Label(model.isCapturing ? "Pause" : "Resume", systemImage: model.isCapturing ? "pause.fill" : "play.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
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
            .buttonStyle(.bordered)
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
                            .background(.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Copy \(clip.title)")
                    }
                }
            }
        }
        .padding(14)
        .background(islandBackground, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(islandStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 14)
    }

    private var statusOrb: some View {
        ZStack {
            Circle()
                .fill(model.isCapturing ? Color.green.opacity(0.22) : Color.orange.opacity(0.2))
                .frame(width: 28, height: 28)
                .scaleEffect(pulse && model.isCapturing ? 1.25 : 0.96)
                .opacity(pulse && model.isCapturing ? 0.42 : 0.9)

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
           let data = latestClip.previewData,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
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

    private var islandBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(nsColor: .black).opacity(0.88),
                Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.9),
                model.isCapturing ? Color.blue.opacity(0.55) : Color.gray.opacity(0.28)
            ],
            startPoint: pulse ? .topLeading : .bottomLeading,
            endPoint: .bottomTrailing
        )
    }

    private var islandStroke: LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(0.22),
                model.isCapturing ? .cyan.opacity(0.5) : .white.opacity(0.1),
                .white.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
        case .text: .white
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
