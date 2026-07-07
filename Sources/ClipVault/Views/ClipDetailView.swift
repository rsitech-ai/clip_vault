import AppKit
import ClipVaultCore
import SwiftUI

struct ClipDetailView: View {
    @Bindable var model: ClipVaultViewModel
    @State private var pendingDeleteClip: Clip?

    var body: some View {
        Group {
            if let clip = model.selectedClip {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ClipDetailHeader(
                            clip: clip,
                            model: model,
                            requestDelete: {
                                pendingDeleteClip = clip
                            }
                        )

                        clipBody(for: clip)

                        if clip.kind == .image {
                            ScreenshotAnnotationPanel(clip: clip, model: model)
                        }

                        ClipTagsEditor(clip: clip, model: model)
                        ClipNoteEditor(clip: clip, model: model)

                        FlowTags(tags: clip.collectionIDs)
                    }
                    .padding(24)
                }
            } else {
                ContentUnavailableView("Select a Clip", systemImage: "sparkle.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.regularMaterial)
        .confirmationDialog(
            "Delete Clip?",
            isPresented: Binding(
                get: { pendingDeleteClip != nil },
                set: { if !$0 { pendingDeleteClip = nil } }
            ),
            presenting: pendingDeleteClip
        ) { clip in
            Button("Delete Clip", role: .destructive) {
                model.delete(clip)
                pendingDeleteClip = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteClip = nil
            }
        } message: { clip in
            Text("Delete \"\(clip.title)\" from ClipVault. This cannot be undone.")
        }
    }
}

private struct ClipDetailHeader: View {
    var clip: Clip
    @Bindable var model: ClipVaultViewModel
    var requestDelete: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                titleBlock
                Spacer(minLength: 12)
                actionButtons
            }

            VStack(alignment: .leading, spacing: 10) {
                titleBlock
                actionButtons
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditableClipTitle(clip: clip, model: model)
            Text("\(clip.kind.title) • \(clip.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
    }

    private var actionButtons: some View {
        ClipVaultGlassContainer(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    model.copyToClipboard(clip)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .clipVaultGlassButtonStyle(prominent: true)
                .help("Copy this clip to the clipboard")

                Button {
                    model.togglePinned(clip)
                } label: {
                    Label(clip.isPinned ? "Unpin" : "Pin", systemImage: clip.isPinned ? "pin.fill" : "pin")
                }
                .clipVaultGlassButtonStyle()
                .help(clip.isPinned ? "Unpin this clip" : "Pin this clip")

                Button(role: .destructive) {
                    requestDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .clipVaultGlassButtonStyle()
                .help("Delete this clip")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct EditableClipTitle: View {
    var clip: Clip
    @Bindable var model: ClipVaultViewModel
    @State private var draft = ""

    var body: some View {
        TextField("Clip title", text: $draft)
            .font(.title2.weight(.semibold))
            .textFieldStyle(.plain)
            .onAppear {
                draft = clip.title
            }
            .onChange(of: clip.id) {
                draft = clip.title
            }
            .onSubmit {
                model.updateTitle(for: clip, title: draft)
            }
            .contextMenu {
                Button("Save Title") {
                    model.updateTitle(for: clip, title: draft)
                }
            }
    }
}

struct ClipTagsEditor: View {
    var clip: Clip
    @Bindable var model: ClipVaultViewModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Tags", systemImage: "tag")
                    .font(.headline)
                Spacer()
                if draft != clip.tags.joined(separator: ", ") {
                    Button("Save") {
                        model.updateTags(for: clip, tagsText: draft)
                    }
                }
            }
            TextField("error, stripe, design", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onAppear {
                    draft = clip.tags.joined(separator: ", ")
                }
                .onChange(of: clip.id) {
                    draft = clip.tags.joined(separator: ", ")
                }
                .onSubmit {
                    model.updateTags(for: clip, tagsText: draft)
                }
        }
    }
}

struct ScreenshotAnnotationPanel: View {
    var clip: Clip
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Screenshot Annotation", systemImage: "photo.badge.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button {
                    model.selectedClipID = clip.id
                    model.selectedClipIDs = [clip.id]
                    model.runAIAction(.todos)
                } label: {
                    Label("Extract action items", systemImage: "checklist")
                }
            }

            HStack(spacing: 14) {
                annotationStat("Source", clip.sourceApp ?? "Unknown")
                annotationStat("OCR", "\(clip.extractedText.split(whereSeparator: \.isNewline).count) lines")
                annotationStat("Copies", "\(clip.copyCount)")
            }
        }
        .padding(14)
        .clipVaultGlassSurface(cornerRadius: 14, tint: .blue.opacity(0.10))
    }

    private func annotationStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ClipNoteEditor: View {
    var clip: Clip
    @Bindable var model: ClipVaultViewModel
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Notes for this clip", systemImage: "note.text")
                    .font(.headline)
                Spacer()
                if draft != clip.userNote {
                    Button("Save") {
                        model.updateNote(for: clip, note: draft)
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                }
            }

            TextEditor(text: $draft)
                .font(.body)
                .focused($isFocused)
                .frame(minHeight: clip.kind == .image ? 110 : 82)
                .padding(8)
                .scrollContentBackground(.hidden)
                .clipVaultGlassSurface(cornerRadius: 10, interactive: true)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isFocused ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                }
                .onAppear {
                    draft = clip.userNote
                }
                .onChange(of: clip.id) {
                    draft = clip.userNote
                }
                .onSubmit {
                    model.updateNote(for: clip, note: draft)
                }

            Text("Use this to annotate screenshots, copied errors, designs, or snippets without changing the original clipboard payload.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private extension ClipDetailView {
    @ViewBuilder
    func clipBody(for clip: Clip) -> some View {
        if clip.kind == .image {
            if let data = clip.previewData {
                CachedClipImageView(
                    data: data,
                    cacheKey: clip.previewImageCacheKey,
                    contentMode: .fit,
                    placeholderSystemImage: "photo"
                )
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.quaternary, lineWidth: 1)
                    }
            }

            if !clip.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Text recognized from image", systemImage: "text.viewfinder")
                        .font(.headline)
                    Text(clip.extractedText)
                        .font(.system(.body, design: .default))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .clipVaultGlassSurface(cornerRadius: 14)
            } else {
                ContentUnavailableView("No text recognized", systemImage: "text.viewfinder")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        } else {
            Text(clip.extractedText.isEmpty ? clip.preview : clip.extractedText)
                .font(.system(.body, design: clip.kind == .code || clip.kind == .sql ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .clipVaultGlassSurface(cornerRadius: 14)
        }
    }
}

struct FlowTags: View {
    var tags: [String]

    var body: some View {
        HStack {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .clipVaultGlassCapsule()
            }
        }
    }
}
