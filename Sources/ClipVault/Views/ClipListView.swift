import AppKit
import ClipVaultCore
import SwiftUI

struct ClipListView: View {
    @Bindable var model: ClipVaultViewModel
    @State private var showCleanup = false
    @State private var pendingDeleteClip: Clip?
    @State private var confirmClearUnpinned = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.visibleResults.isEmpty {
                ContentUnavailableView(
                    "No Clips",
                    systemImage: "doc.on.clipboard",
                    description: Text(model.searchText.isEmpty ? "Copy something to begin." : "No matching clips.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.visibleResults) { result in
                                draggableClipRow(clip: result.clip) {
                                    ClipRowView(
                                        result: result,
                                        isSelectedForAI: model.selectedClipIDs.contains(result.clip.id),
                                        toggleAISelection: {
                                            model.select(result.clip)
                                        }
                                    )
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .id(result.clip.id)
                                    .contentShape(Rectangle())
                                    .background {
                                        RoundedRectangle(
                                            cornerRadius: ClipVaultDesign.rowRadius,
                                            style: .continuous
                                        )
                                        .fill(rowBackground(for: result.clip))
                                        .padding(.horizontal, 4)
                                    }
                                    .onTapGesture(count: 2) {
                                        model.selectAndCopy(result.clip)
                                    }
                                    .onTapGesture {
                                        model.selectedClipID = result.clip.id
                                    }
                                    .contextMenu {
                                        Button("Copy") {
                                            model.copyToClipboard(result.clip)
                                        }
                                        Button(model.selectedClipIDs.contains(result.clip.id) ? "Remove from AI Selection" : "Add to AI Selection") {
                                            model.select(result.clip)
                                        }
                                        Button(result.clip.isPinned ? "Unpin" : "Pin") {
                                            model.togglePinned(result.clip)
                                        }
                                        MoveToCollectionMenu(
                                            clip: result.clip,
                                            model: model,
                                            label: "Move to Collection"
                                        )
                                        Button("Delete", role: .destructive) {
                                            pendingDeleteClip = result.clip
                                        }
                                    }
                                    .accessibilityAddTraits(model.selectedClipID == result.clip.id ? .isSelected : [])
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .focusable()
                    .onMoveCommand(perform: moveSelection)
                    .onKeyPress(.return) {
                        guard let selectedClip = model.selectedClip else { return .ignored }
                        model.copyToClipboard(selectedClip)
                        return .handled
                    }
                    .onChange(of: model.selectedClipID) { _, selectedClipID in
                        guard let selectedClipID else { return }
                        proxy.scrollTo(selectedClipID, anchor: .center)
                    }
                }
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
        .confirmationDialog("Clear Unpinned Clips?", isPresented: $confirmClearUnpinned) {
            Button("Clear Unpinned Clips", role: .destructive) {
                model.clearUnpinnedClips()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove every unpinned clip from ClipVault. Pinned clips will stay.")
        }
    }

    private func rowBackground(for clip: Clip) -> Color {
        model.selectedClipID == clip.id ? Color.accentColor.opacity(0.14) : Color.clear
    }

    @ViewBuilder
    private func draggableClipRow<Content: View>(
        clip: Clip,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let payload = ClipMovePayload(clipID: clip.id) {
            content()
                .draggable(payload) {
                    HStack(spacing: 8) {
                        Image(systemName: ClipVaultDesign.icon(for: clip.kind))
                            .foregroundStyle(ClipVaultDesign.tint(for: clip.kind))
                        Text(clip.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator.opacity(0.7), lineWidth: 1)
                    }
                }
        } else {
            content()
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let clips = model.visibleClips
        guard !clips.isEmpty else { return }

        let currentIndex = clips.firstIndex { $0.id == model.selectedClipID } ?? 0
        let offset = direction == .down ? 1 : direction == .up ? -1 : 0
        guard offset != 0 else { return }
        let nextIndex = min(max(currentIndex + offset, 0), clips.count - 1)
        model.selectedClipID = clips[nextIndex].id
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedCollectionTitle)
                    .font(.headline)
                Text(resultCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.selectedClipIDs.isEmpty {
                Text("\(model.selectedClipIDs.count) selected")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .clipVaultGlassCapsule(tint: .accentColor.opacity(0.10))
            }
            Menu {
                Button("Bulk Cleanup") {
                    showCleanup = true
                }
                Button("Clear Unpinned Clips", role: .destructive) {
                    confirmClearUnpinned = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Open cleanup actions")
            .accessibilityLabel("Clip cleanup actions")
        }
        .padding(14)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .sheet(isPresented: $showCleanup) {
            BulkCleanupView(model: model)
                .frame(width: 560, height: 460)
        }
    }

    private var resultCountLabel: String {
        let count = model.visibleResults.count
        if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(count) \(count == 1 ? "clip" : "clips")"
        }
        return "\(count) \(count == 1 ? "match" : "matches")"
    }
}

struct ClipRowView: View {
    var result: SearchResult
    var isSelectedForAI: Bool
    var toggleAISelection: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleAISelection) {
                Image(systemName: isSelectedForAI ? "checkmark.circle.fill" : "circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isSelectedForAI ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isSelectedForAI ? "Remove clip from AI selection" : "Add clip to AI selection")
            .accessibilityLabel(isSelectedForAI ? "Remove clip from AI selection" : "Add clip to AI selection")

            thumbnail
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.clip.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(result.clip.kind.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if result.clip.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if result.clip.copyCount > 1 {
                Text("x\(result.clip.copyCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ClipTimestampText(date: result.clip.createdAt)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(height: 44)
        .help(result.clip.preview.isEmpty ? result.clip.title : result.clip.preview)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if result.clip.kind == .image,
           let data = result.clip.previewData {
            CachedClipImageView(
                data: data,
                cacheKey: result.clip.previewImageCacheKey,
                contentMode: .fill,
                placeholderSystemImage: "photo"
            )
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Image(systemName: icon)
                .foregroundStyle(ClipVaultDesign.tint(for: result.clip.kind))
                .frame(width: 34, height: 34)
                .background(
                    ClipVaultDesign.tint(for: result.clip.kind).opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
    }

    private var icon: String {
        ClipVaultDesign.icon(for: result.clip.kind)
    }
}

struct BulkCleanupView: View {
    @Bindable var model: ClipVaultViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteMatches = false
    @State private var candidates: [Clip] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bulk Cleanup")
                        .font(.title2.weight(.semibold))
                    Text("Review noisy clipboard groups before removing them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }

            Picker("Filter", selection: $model.cleanupFilter) {
                ForEach(CleanupFilter.allCases) { filter in
                    Label(filter.rawValue, systemImage: filter.systemImage)
                        .tag(filter)
                }
            }
            .pickerStyle(.segmented)

            List(candidates) { clip in
                HStack {
                    Image(systemName: ClipVaultDesign.icon(for: clip.kind))
                        .frame(width: 24)
                        .foregroundStyle(ClipVaultDesign.tint(for: clip.kind))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clip.title)
                            .lineLimit(1)
                        Text("\(clip.kind.title) • \(clip.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if clip.copyCount > 1 {
                        Text("x\(clip.copyCount)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView("Nothing to Clean", systemImage: "checkmark.circle")
                }
            }

            HStack {
                Text("\(candidates.count) matching clips")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete Matches", role: .destructive) {
                    confirmDeleteMatches = true
                }
                .clipVaultGlassButtonStyle()
                .disabled(candidates.isEmpty)
                .help(candidates.isEmpty ? "No clips match the current cleanup filter" : "Delete clips matching the current cleanup filter")
            }
        }
        .padding(20)
        .background(.regularMaterial)
        .onAppear(perform: refreshCandidates)
        .onChange(of: model.cleanupFilter) {
            refreshCandidates()
        }
        .onChange(of: model.clips) {
            refreshCandidates()
        }
        .confirmationDialog("Delete Matching Clips?", isPresented: $confirmDeleteMatches) {
            Button("Delete Matches", role: .destructive) {
                model.deleteCleanupCandidates(for: model.cleanupFilter)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \(candidates.count) clips matching the current cleanup filter. This cannot be undone.")
        }
    }

    private func refreshCandidates() {
        candidates = model.cleanupCandidates(for: model.cleanupFilter)
    }

}
