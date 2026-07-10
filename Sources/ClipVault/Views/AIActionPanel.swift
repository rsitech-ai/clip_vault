import ClipVaultCore
import SwiftUI

struct AIActionPanel: View {
    @Bindable var model: ClipVaultViewModel
    var placement: AIActionPanelPlacement = .inspector

    @ViewBuilder
    var body: some View {
        switch placement {
        case .inspector:
            inspectorLayout
                .padding(18)
                .clipVaultGlassSurface(
                    cornerRadius: ClipVaultDesign.panelRadius,
                    tint: panelTint
                )
                .clipVaultPanelShadow(active: true)
                .padding(10)
        case .inline:
            inlineLayout
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
    }

    private var panelTint: Color {
        model.aiAvailability.isAvailable
            ? .accentColor.opacity(0.05)
            : .orange.opacity(0.08)
    }

    private var inspectorLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            actionGrid

            ViewThatFits(in: .horizontal) {
                askRow
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Ask selected clips", text: $model.question)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.runAIAction(.ask)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: ClipVaultDesign.icon(for: .ask))
                            Text("Ask")
                        }
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .clipVaultGlassButtonStyle(prominent: true)
                    .disabled(!model.canAskQuestion)
                    .help(askHelp)
                }
            }

            Divider()

            resultArea
                .frame(minHeight: 120, alignment: .topLeading)

            Spacer(minLength: 0)
        }
    }

    private var inlineLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            inlineActionToolbar

            inlineResultArea
                .frame(
                    maxWidth: .infinity,
                    minHeight: 120,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )

            Divider()
            askRow
        }
    }

    private var actionGrid: some View {
        ClipVaultGlassContainer(spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 106), spacing: 8)], alignment: .leading, spacing: 8) {
                actionButtons
            }
        }
    }

    private var inlineActionToolbar: some View {
        HStack(spacing: 8) {
            ForEach(Self.visibleActionKinds, id: \.self) { action in
                compactActionButton(for: action)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(Self.visibleActionKinds, id: \.self) { action in
            actionButton(for: action)
        }
    }

    private func actionButton(for action: AIActionKind) -> some View {
        let tint = ClipVaultDesign.tint(for: action)
        return Button {
            model.runAIAction(action)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: ClipVaultDesign.icon(for: action))
                    .foregroundStyle(tint)
                Text(action.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
        }
        .tint(tint)
        .clipVaultGlassButtonStyle()
        .disabled(model.isGenerating)
        .help(model.isGenerating ? "Wait for the current AI action to finish" : actionHelp(for: action))
        .accessibilityHint(ClipVaultDesign.hint(for: action))
    }

    private func compactActionButton(for action: AIActionKind) -> some View {
        let tint = ClipVaultDesign.tint(for: action)
        return Button {
            model.runAIAction(action)
        } label: {
            Label(action.title, systemImage: ClipVaultDesign.icon(for: action))
                .labelStyle(.iconOnly)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .clipVaultGlassSurface(cornerRadius: 9, tint: tint.opacity(0.12), interactive: true)
        }
        .buttonStyle(.plain)
        .opacity(model.isGenerating ? 0.55 : 1)
        .disabled(model.isGenerating)
        .help(model.isGenerating ? "Wait for the current AI action to finish" : actionHelp(for: action))
        .accessibilityLabel(Text(action.title))
        .accessibilityHint(Text(ClipVaultDesign.hint(for: action)))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Workspace")
                    .font(.headline)
                Text(contextText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            availabilityBadge
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if model.isGenerating {
            ProgressView("Thinking")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = model.aiError {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let result = model.aiResult {
            ScrollView {
                generatedResult(result)
            }
            .scrollIndicators(.visible)
        } else {
            emptyResultState
        }
    }

    private var resultArea: some View {
        resultContent
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipVaultGlassSurface(cornerRadius: ClipVaultDesign.sectionRadius)
    }

    private var inlineResultArea: some View {
        resultContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func generatedResult(_ result: AIActionResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(result.title)
                    .font(.headline)
                Spacer()
                if result.isFallback {
                    Text("Local")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .clipVaultGlassCapsule(tint: .secondary.opacity(0.10))
                }
            }
            Text(result.content)
                .font(.callout)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !result.citedClipIDs.isEmpty {
                Text(clipCountText(result.citedClipIDs.count, suffix: "cited"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 4)
    }

    private var emptyResultState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(contextText, systemImage: "checkmark.circle")
                .font(.callout)
            Text("Use an action above, or ask a custom question. When nothing is selected, ClipVault uses the open clip.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var availabilityText: String {
        if model.aiAvailability.isAvailable {
            return "Foundation Models ready"
        }
        return model.aiAvailability.reason ?? "AI unavailable"
    }

    private var contextText: String {
        if !model.selectedClips.isEmpty {
            return clipCountText(model.selectedClips.count, suffix: "selected")
        }
        if model.selectedClip != nil {
            return "Using open clip"
        }
        return "No clip available"
    }

    private func clipCountText(_ count: Int, suffix: String) -> String {
        "\(count) \(count == 1 ? "clip" : "clips") \(suffix)"
    }

    private var askRow: some View {
        HStack(spacing: 8) {
            TextField(askPlaceholder, text: $model.question)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: placement.askMinimumWidth)
                .layoutPriority(1)
            Button {
                model.runAIAction(.ask)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: ClipVaultDesign.icon(for: .ask))
                    Text("Ask")
                }
                .font(.caption.weight(.semibold))
            }
            .tint(ClipVaultDesign.tint(for: .ask))
            .fixedSize(horizontal: true, vertical: false)
            .clipVaultGlassButtonStyle(prominent: true)
            .disabled(!model.canAskQuestion)
            .help(askHelp)
            .accessibilityHint(ClipVaultDesign.hint(for: .ask))
        }
    }

    private var askPlaceholder: String {
        model.selectedClips.isEmpty ? "Ask about the open clip" : "Ask selected clips"
    }

    private var askHelp: String {
        if model.isGenerating {
            return "Wait for the current AI action to finish"
        }
        if model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type a question first"
        }
        return "Ask a question about the selected clips"
    }

    private func actionHelp(for action: AIActionKind) -> String {
        "\(action.title): \(ClipVaultDesign.hint(for: action))"
    }

    @ViewBuilder
    private var availabilityBadge: some View {
        switch placement {
        case .inspector:
            Label(model.aiAvailability.isAvailable ? "Ready" : "Local fallback", systemImage: model.aiAvailability.isAvailable ? "sparkles" : "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.aiAvailability.isAvailable ? Color.accentColor : Color.orange)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .clipVaultGlassCapsule(tint: model.aiAvailability.isAvailable ? .accentColor.opacity(0.10) : .orange.opacity(0.10))
                .help(availabilityText)
        case .inline:
            inlineAvailabilityIndicator
        }
    }

    private var inlineAvailabilityIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.aiAvailability.isAvailable ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(model.aiAvailability.isAvailable ? "Ready" : "Fallback")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .help(availabilityText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(availabilityText)
    }

    private static let visibleActionKinds: [AIActionKind] = [.summarize, .explain, .todos]
}

enum AIActionPanelPlacement {
    case inspector
    case inline

    var askMinimumWidth: CGFloat {
        switch self {
        case .inspector: 180
        case .inline: 160
        }
    }
}
