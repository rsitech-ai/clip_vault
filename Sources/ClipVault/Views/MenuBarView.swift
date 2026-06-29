import AppKit
import ClipVaultCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: ClipVaultViewModel
    var openWorkspace: () -> Void
    @State private var hoveredClipID: String?
    @State private var previewPinned = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Maccy  type to search...", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model.searchText) {
                        model.statusMenuFocusIndex = 0
                    }

                ScrollViewReader { proxy in
                    ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(model.visibleResults.prefix(12).enumerated()), id: \.element.id) { index, result in
                            MenuClipRow(
                                clip: result.clip,
                                isHovered: hoveredClipID == result.clip.id || model.statusMenuFocusIndex == index,
                                copy: {
                                    model.selectAndCopy(result.clip)
                                    model.statusMenuFocusIndex = index
                                    hoveredClipID = result.clip.id
                                },
                                openWorkspace: {
                                    model.selectedClipID = result.clip.id
                                    openWorkspace()
                                },
                                togglePin: {
                                    model.togglePinned(result.clip)
                                },
                                delete: {
                                    model.delete(result.clip)
                                }
                            )
                            .onHover { isHovering in
                                if isHovering {
                                    model.statusMenuFocusIndex = index
                                    hoveredClipID = result.clip.id
                                }
                            }
                            .id(result.clip.id)
                        }
                    }
                }
                    .frame(maxHeight: 460)
                    .onChange(of: model.statusMenuFocusIndex) {
                        guard model.visibleClips.indices.contains(model.statusMenuFocusIndex) else { return }
                        proxy.scrollTo(model.visibleClips[model.statusMenuFocusIndex].id, anchor: .center)
                    }
                }

                HStack {
                    Button {
                        openWorkspace()
                    } label: {
                        Label("Workspace", systemImage: "rectangle.3.group")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button {
                        model.toggleCapture()
                    } label: {
                        Image(systemName: model.isCapturing ? "pause.circle" : "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(model.isCapturing ? "Pause clipboard capture" : "Resume clipboard capture")
                    .accessibilityLabel(model.isCapturing ? "Pause clipboard capture" : "Resume clipboard capture")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(width: 420)

            if let previewClip {
                Divider()
                MenuClipPreview(clip: previewClip, isPinned: previewPinned)
                    .frame(width: 400)
                    .frame(minHeight: 280, maxHeight: 540)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .background(MenuKeyboardCatcher { action in
            handleKeyboard(action)
        })
        .animation(.snappy(duration: 0.16), value: hoveredClipID)
    }

    private var previewClip: Clip? {
        if let focused = model.focusedMenuClip {
            return focused
        }
        if let hoveredClipID,
           let hovered = model.visibleResults.map(\.clip).first(where: { $0.id == hoveredClipID }) {
            return hovered
        }

        return model.visibleResults.first?.clip
    }

    private func handleKeyboard(_ action: MenuKeyboardAction) {
        switch action {
        case .up:
            model.moveMenuFocus(-1)
            hoveredClipID = model.focusedMenuClip?.id
        case .down:
            model.moveMenuFocus(1)
            hoveredClipID = model.focusedMenuClip?.id
        case .copy:
            model.copyFocusedMenuClip()
        case .preview:
            previewPinned.toggle()
        case .delete:
            model.deleteFocusedMenuClip()
            hoveredClipID = model.focusedMenuClip?.id
        case .pin:
            model.togglePinnedFocusedMenuClip()
        }
    }
}

private struct MenuClipRow: View {
    var clip: Clip
    var isHovered: Bool
    var copy: () -> Void
    var openWorkspace: () -> Void
    var togglePin: () -> Void
    var delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            MenuClipThumbnail(clip: clip, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(clip.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if clip.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(clip.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if clip.copyCount > 1 {
                    Text("x\(clip.copyCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(clip.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 56)
        .padding(.horizontal, 8)
        .background(isHovered ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(isHovered ? Color.white : Color.primary)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: copy)
        .contextMenu {
            Button("Copy") {
                copy()
            }
            Button("Open in Workspace") {
                openWorkspace()
            }
            Button(clip.isPinned ? "Unpin" : "Pin") {
                togglePin()
            }
            Button("Delete", role: .destructive) {
                delete()
            }
        }
        .accessibilityLabel("\(clip.title), \(clip.kind.title)")
        .accessibilityHint("Click to copy this clip. Open the context menu for pin, workspace, or delete actions.")
    }
}

private struct MenuClipThumbnail: View {
    var clip: Clip
    var size: CGFloat

    var body: some View {
        Group {
            if clip.kind == .image,
               let data = clip.previewData,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: icon(for: clip.kind))
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.quaternary, lineWidth: 1)
        }
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
        case .unknown: "doc"
        }
    }
}

private struct MenuClipPreview: View {
    var clip: Clip
    var isPinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if clip.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.orange)
                }
            }

            previewBody

            HStack {
                Text("Enter copies • Space pins preview • Delete removes • P pins")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if isPinned {
                    Image(systemName: "eye.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Preview pinned")
                }
            }
        }
        .padding(14)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var previewBody: some View {
        if clip.kind == .image,
           let data = clip.previewData,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 260)
                .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if !clip.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    Text(clip.extractedText)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            ScrollView {
                Text(clip.extractedText.isEmpty ? clip.preview : clip.extractedText)
                    .font(.system(.caption, design: clip.kind == .code || clip.kind == .sql ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var metadata: String {
        let source = clip.sourceApp ?? "Unknown app"
        return "\(clip.kind.title) • \(source) • \(clip.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private enum MenuKeyboardAction {
    case up
    case down
    case copy
    case preview
    case delete
    case pin
}

private struct MenuKeyboardCatcher: NSViewRepresentable {
    var handle: (MenuKeyboardAction) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handle = handle
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.handle = handle
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class KeyView: NSView {
        var handle: ((MenuKeyboardAction) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126:
                handle?(.up)
            case 125:
                handle?(.down)
            case 36, 76:
                handle?(.copy)
            case 49:
                handle?(.preview)
            case 51, 117:
                handle?(.delete)
            default:
                if event.charactersIgnoringModifiers?.lowercased() == "p" {
                    handle?(.pin)
                } else {
                    super.keyDown(with: event)
                }
            }
        }
    }
}
