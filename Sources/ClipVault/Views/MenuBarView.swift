import AppKit
import ClipVaultCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: ClipVaultViewModel
    @Environment(\.openSettings) private var openSettings
    var openWorkspace: () -> Void
    @State private var hoveredClipID: String?
    @State private var previewPinned = false
    @State private var menuWindowBox = MenuWindowBox()
    @State private var keyboardScrollTargetID: String?
    private let menuResultLimit = 80

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let previewClip {
                MenuClipPreview(clip: previewClip, isPinned: previewPinned)
                    .frame(width: 360)
                    .frame(minHeight: 280, maxHeight: 540)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                Divider()
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Search clips...", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model.searchText) {
                        model.statusMenuFocusIndex = 0
                        keyboardScrollTargetID = nil
                        hoveredClipID = nil
                    }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(menuResults.enumerated()), id: \.element.id) { index, result in
                                MenuClipRow(
                                    clip: result.clip,
                                    isHovered: hoveredClipID == result.clip.id || model.statusMenuFocusIndex == index,
                                    copy: {
                                        copyFromMenu(result.clip, at: index)
                                    },
                                    openWorkspace: {
                                        performAndClose {
                                            model.selectedClipID = result.clip.id
                                            openWorkspace()
                                        }
                                    },
                                    togglePin: {
                                        performAndClose {
                                            model.togglePinned(result.clip)
                                        }
                                    },
                                    delete: {
                                        performAndClose {
                                            model.delete(result.clip)
                                        }
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
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 470)
                    .scrollIndicators(.visible)
                    .onAppear {
                        clampMenuFocus()
                    }
                    .onChange(of: menuResultIDs) {
                        clampMenuFocus()
                    }
                    .onChange(of: keyboardScrollTargetID) {
                        guard let keyboardScrollTargetID else { return }
                        withAnimation(.snappy(duration: 0.12)) {
                            proxy.scrollTo(keyboardScrollTargetID, anchor: .center)
                        }
                        self.keyboardScrollTargetID = nil
                    }
                }

                ClipVaultGlassContainer(spacing: 8) {
                    HStack {
                        Button {
                            performAndClose { openWorkspace() }
                        } label: {
                            Label("Workspace", systemImage: "rectangle.3.group")
                        }
                        .clipVaultGlassButtonStyle()

                        Spacer()

                        Button {
                            captureAfterClosingMenu()
                        } label: {
                            Label("Shot", systemImage: "camera.viewfinder")
                        }
                        .clipVaultGlassButtonStyle()
                        .help("Capture a custom area or window screenshot with Command-Shift-2")

                        SponsorButton(action: {
                            performAndClose(SponsorButton.openSponsorPage)
                        })
                            .clipVaultGlassButtonStyle()
                            .help("Support ClipVault on Buy Me a Coffee")

                        Button {
                            performAndClose { openSettings() }
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .clipVaultGlassButtonStyle()
                        .help("Open ClipVault settings")
                        .accessibilityLabel("Open ClipVault settings")

                        Button {
                            performAndClose { model.toggleCapture() }
                        } label: {
                            Image(systemName: model.isCapturing ? "pause.circle" : "play.circle")
                        }
                        .clipVaultGlassButtonStyle(prominent: model.isCapturing)
                        .help(model.isCapturing ? "Pause clipboard capture" : "Resume clipboard capture")
                        .accessibilityLabel(model.isCapturing ? "Pause clipboard capture" : "Resume clipboard capture")
                        .accessibilityHint(
                            model.isCapturing
                                ? "Stops saving new clipboard items until capture is resumed."
                                : "Starts saving new clipboard items to ClipVault."
                        )
                    }
                }
                .font(.caption)
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(width: 380)
        }
        .background(
            MenuKeyboardCatcher(
                handle: { action in
                    handleKeyboard(action)
                },
                onWindowChange: { window in
                    menuWindowBox.window = window
                }
            )
        )
        .animation(.snappy(duration: 0.16), value: hoveredClipID)
        .task {
            await model.bootstrap()
        }
    }

    private var menuResults: [SearchResult] {
        Array(model.visibleResults.prefix(menuResultLimit))
    }

    private var menuClips: [Clip] {
        menuResults.map(\.clip)
    }

    private var menuResultIDs: [String] {
        menuResults.map(\.id)
    }

    private var focusedMenuClip: Clip? {
        guard !menuClips.isEmpty else { return nil }
        let index = min(max(model.statusMenuFocusIndex, 0), menuClips.count - 1)
        return menuClips[index]
    }

    private var previewClip: Clip? {
        if let focused = focusedMenuClip {
            return focused
        }
        if let hoveredClipID,
           let hovered = menuClips.first(where: { $0.id == hoveredClipID }) {
            return hovered
        }

        return menuClips.first
    }

    private func copyFromMenu(_ clip: Clip, at index: Int) {
        performAndClose {
            model.selectAndCopy(clip)
            model.statusMenuFocusIndex = index
            hoveredClipID = clip.id
        }
    }

    private func copyFocusedFromMenu() {
        guard let focusedMenuClip else { return }
        performAndClose {
            model.selectAndCopy(focusedMenuClip)
            hoveredClipID = focusedMenuClip.id
        }
    }

    private func moveMenuFocus(_ delta: Int) {
        guard !menuClips.isEmpty else {
            model.statusMenuFocusIndex = 0
            hoveredClipID = nil
            return
        }
        let nextIndex = min(max(model.statusMenuFocusIndex + delta, 0), menuClips.count - 1)
        model.statusMenuFocusIndex = nextIndex
        model.selectedClipID = menuClips[nextIndex].id
        hoveredClipID = menuClips[nextIndex].id
        keyboardScrollTargetID = menuClips[nextIndex].id
    }

    private func deleteFocusedMenuClip() {
        guard let clip = focusedMenuClip else { return }
        performAndClose {
            model.delete(clip)
            model.statusMenuFocusIndex = min(model.statusMenuFocusIndex, max(menuClips.count - 1, 0))
            hoveredClipID = focusedMenuClip?.id
        }
    }

    private func togglePinnedFocusedMenuClip() {
        guard let clip = focusedMenuClip else { return }
        performAndClose {
            model.togglePinned(clip)
        }
    }

    private func clampMenuFocus() {
        guard !menuClips.isEmpty else {
            model.statusMenuFocusIndex = 0
            hoveredClipID = nil
            return
        }

        let clamped = min(max(model.statusMenuFocusIndex, 0), menuClips.count - 1)
        if clamped != model.statusMenuFocusIndex {
            model.statusMenuFocusIndex = clamped
        }

        if let hoveredClipID, !menuClips.contains(where: { $0.id == hoveredClipID }) {
            self.hoveredClipID = menuClips[clamped].id
        }
    }

    private func closeMenuWindow() {
        guard let window = menuWindowBox.window else { return }
        window.resignKey()
        window.orderOut(nil)
    }

    private func performAndClose(_ action: @MainActor () -> Void) {
        closeMenuWindow()
        action()
    }

    private func captureAfterClosingMenu() {
        closeMenuWindow()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            model.captureInteractiveScreenshot()
        }
    }

    private func handleKeyboard(_ action: MenuKeyboardAction) {
        switch action {
        case .up:
            moveMenuFocus(-1)
        case .down:
            moveMenuFocus(1)
        case .copy:
            copyFocusedFromMenu()
        case .preview:
            previewPinned.toggle()
        case .delete:
            deleteFocusedMenuClip()
        case .pin:
            togglePinnedFocusedMenuClip()
        }
    }
}

private final class MenuWindowBox {
    weak var window: NSWindow?
}

private struct MenuClipRow: View {
    var clip: Clip
    var isHovered: Bool
    var copy: () -> Void
    var openWorkspace: () -> Void
    var togglePin: () -> Void
    var delete: () -> Void

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 8) {
                MenuClipThumbnail(clip: clip, size: 30)

                Text(compactTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if clip.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(isHovered ? Color.white.opacity(0.9) : Color.orange)
                }

                if clip.copyCount > 1 {
                    Text("x\(clip.copyCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isHovered ? Color.white.opacity(0.78) : Color.secondary)
                        .monospacedDigit()
                }

                ClipTimestampText(date: clip.createdAt)
                    .font(.caption2)
                    .foregroundStyle(isHovered ? Color.white.opacity(0.72) : Color.secondary.opacity(0.62))
                    .monospacedDigit()
            }
            .frame(height: 36)
            .padding(.horizontal, 8)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(isHovered ? Color.white : Color.primary)
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
        .accessibilityHint("Copies this clip to the clipboard. The context menu also opens, pins, or deletes it.")
        .help(clip.preview.isEmpty ? clip.title : clip.preview)
    }

    private var compactTitle: String {
        MenuText.short(clip.title.isEmpty ? clip.preview : clip.title, limit: 30)
    }
}

private struct MenuClipThumbnail: View {
    var clip: Clip
    var size: CGFloat

    var body: some View {
        Group {
            if clip.kind == .image,
               let data = clip.previewData {
                CachedClipImageView(
                    data: data,
                    cacheKey: clip.previewImageCacheKey,
                    contentMode: .fill,
                    placeholderSystemImage: "photo"
                )
            } else {
                Image(systemName: icon(for: clip.kind))
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipVaultGlassSurface(cornerRadius: 6)
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
                Text("Enter copies • Space locks preview • Delete removes • P pins")
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
        .clipVaultGlassSurface(cornerRadius: 0)
    }

    @ViewBuilder
    private var previewBody: some View {
        if clip.kind == .image,
           let data = clip.previewData {
            CachedClipImageView(
                data: data,
                cacheKey: clip.previewImageCacheKey,
                contentMode: .fit,
                placeholderSystemImage: "photo"
            )
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
                .clipVaultGlassSurface(cornerRadius: 10)
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
            .clipVaultGlassSurface(cornerRadius: 10)
        }
    }

    private var metadata: String {
        let source = clip.sourceApp ?? "Unknown app"
        return "\(clip.kind.title) • \(source) • \(clip.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private enum MenuText {
    static func short(_ value: String, limit: Int) -> String {
        let trimmed = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else {
            return trimmed
        }

        let headCount = max(8, (limit - 1) / 2)
        let tailCount = max(6, limit - headCount - 1)
        return "\(trimmed.prefix(headCount))…\(trimmed.suffix(tailCount))"
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
    var onWindowChange: (NSWindow?) -> Void = { _ in }

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handle = handle
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
            onWindowChange(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.handle = handle
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
            onWindowChange(nsView.window)
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
