import ClipVaultCore
import SwiftUI

struct AICommandBar: View {
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            expandedBar
            compactBar
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var expandedBar: some View {
        HStack(spacing: 8) {
            contextIndicator
            actionButtons
            enhancePromptButton(labelStyle: .titleAndIcon)
            askField
        }
    }

    private var compactBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Self.visibleActionKinds, id: \.self) { action in
                    Button {
                        model.runAIAction(action)
                    } label: {
                        Label(action.title, systemImage: ClipVaultDesign.icon(for: action))
                    }
                    .disabled(model.isGenerating)
                }
                Divider()
                Button(action: enhancePrompts) {
                    Label("Enhance Prompt", systemImage: ClipVaultDesign.enhancePromptIcon)
                }
                .disabled(!model.canEnhancePrompts)
            } label: {
                Label("AI Actions", systemImage: "sparkles")
                    .labelStyle(.iconOnly)
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.button)
            .help("AI actions for \(contextText.lowercased())")

            askField
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(Self.visibleActionKinds, id: \.self) { action in
            Button {
                model.runAIAction(action)
            } label: {
                Label(action.title, systemImage: ClipVaultDesign.icon(for: action))
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .clipVaultGlassSurface(
                cornerRadius: 9,
                tint: ClipVaultDesign.tint(for: action).opacity(0.10),
                interactive: true
            )
            .clipVaultPressFeedback()
            .disabled(model.isGenerating)
            .help(actionHelp(for: action))
            .accessibilityHint(ClipVaultDesign.hint(for: action))
        }
    }

    private enum CommandLabelStyle {
        case titleAndIcon
    }

    private func enhancePromptButton(labelStyle _: CommandLabelStyle) -> some View {
        Button(action: enhancePrompts) {
            Label("Enhance", systemImage: ClipVaultDesign.enhancePromptIcon)
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .clipVaultGlassSurface(
            cornerRadius: 9,
            tint: ClipVaultDesign.enhancePromptTint.opacity(0.11),
            interactive: true
        )
        .clipVaultPressFeedback()
        .disabled(!model.canEnhancePrompts)
        .help(enhancePromptHelp)
        .accessibilityLabel("Enhance Prompt")
        .accessibilityValue(model.canEnhancePrompts ? "Available" : enhancePromptHelp)
        .accessibilityHint(Self.enhancePromptHint)
    }

    private var askField: some View {
        HStack(spacing: 6) {
            TextField(askPlaceholder, text: $model.question)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 150)
                .layoutPriority(1)
                .onSubmit {
                    guard model.canAskQuestion else { return }
                    model.runAIAction(.ask)
                }
            Button {
                model.runAIAction(.ask)
            } label: {
                Label("Ask", systemImage: ClipVaultDesign.icon(for: .ask))
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .clipVaultGlassSurface(
                cornerRadius: 9,
                tint: ClipVaultDesign.tint(for: .ask).opacity(0.15),
                interactive: true
            )
            .clipVaultPressFeedback()
            .disabled(!model.canAskQuestion)
            .help(askHelp)
            .accessibilityLabel("Ask")
            .accessibilityHint(ClipVaultDesign.hint(for: .ask))
        }
    }

    @ViewBuilder
    private var contextIndicator: some View {
        if !model.selectedClips.isEmpty {
            Text("\(model.selectedClips.count) selected")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var askPlaceholder: String {
        model.selectedClips.isEmpty ? "Ask about this clip" : "Ask selected clips"
    }

    private var contextText: String {
        if !model.selectedClips.isEmpty {
            return "\(model.selectedClips.count) selected clips"
        }
        return "the open clip"
    }

    private var askHelp: String {
        if model.isGenerating {
            return "Wait for the current AI action to finish"
        }
        if model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type a question first"
        }
        return "Ask a question about \(contextText)"
    }

    private var enhancePromptHelp: String {
        if model.isGenerating {
            return "Wait for the current generation to finish."
        }
        if model.selectedClips.isEmpty, model.selectedClip == nil {
            return "Select or open a source clip first."
        }
        if !model.promptEnhancerAvailability.isAvailable {
            return model.promptEnhancerAvailability.reason ?? "Apple Intelligence is unavailable."
        }
        return Self.enhancePromptHint
    }

    private func enhancePrompts() {
        model.runPromptEnhancement()
    }

    private func actionHelp(for action: AIActionKind) -> String {
        model.isGenerating
            ? "Wait for the current AI action to finish"
            : "\(action.title): \(ClipVaultDesign.hint(for: action))"
    }

    private static let visibleActionKinds: [AIActionKind] = [.summarize, .explain, .todos]
    private static let enhancePromptHint = "Creates one improved prompt per source clip and saves the completed batch to Prompts."
}

struct InlineAIResultView: View {
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        if isPresented {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Label("AI Result", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    if canDismiss {
                        Button {
                            model.dismissAIResult()
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .clipVaultPressFeedback()
                        .help("Dismiss AI result")
                        .accessibilityLabel("Dismiss AI result")
                    }
                }
                resultContent
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipVaultGlassSurface(
                cornerRadius: ClipVaultDesign.sectionRadius,
                tint: resultTint
            )
        }
    }

    private var isPresented: Bool {
        model.isGenerating
            || model.aiError != nil
            || model.aiResult != nil
            || model.promptEnhancementState != .idle
    }

    private var canDismiss: Bool {
        !model.isGenerating && !model.promptEnhancementState.blocksAIOperations
    }

    private var resultTint: Color {
        if model.aiError != nil {
            return .red.opacity(0.07)
        }
        if case .failed = model.promptEnhancementState {
            return .red.opacity(0.07)
        }
        return .accentColor.opacity(0.04)
    }

    @ViewBuilder
    private var resultContent: some View {
        switch model.promptEnhancementState {
        case .idle:
            ordinaryResult
        case .enhancing(let current, let total, let sourceTitle):
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: Double(current), total: Double(total))
                    .accessibilityLabel("Prompt enhancement progress")
                    .accessibilityValue("\(current) of \(total)")
                Text("Enhancing \(current) of \(total)")
                    .font(.callout.weight(.medium))
                Text(sourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    model.cancelPromptEnhancement()
                }
                .clipVaultGlassButtonStyle()
            }
        case .saving(let total):
            ProgressView("Saving \(enhancedPromptCountText(total))")
        case .success(let count):
            HStack {
                Label("\(enhancedPromptCountText(count)) saved to Prompts", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Open Prompts") {
                    model.openPrompts()
                }
                .clipVaultGlassButtonStyle(prominent: true)
            }
        case .failed(_, let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .cancelled:
            Text("Prompt enhancement cancelled. Nothing was saved.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var ordinaryResult: some View {
        if model.isGenerating {
            ProgressView("Thinking")
        } else if let error = model.aiError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } else if let result = model.aiResult {
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
                    Text("\(result.citedClipIDs.count) source \(result.citedClipIDs.count == 1 ? "clip" : "clips")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func enhancedPromptCountText(_ count: Int) -> String {
        "\(count) enhanced \(count == 1 ? "prompt" : "prompts")"
    }
}
