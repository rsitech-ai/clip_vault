import ClipVaultCore
import SwiftUI

struct AIActionPanel: View {
    @Bindable var model: ClipVaultViewModel
    var placement: AIActionPanelPlacement = .inspector

    var body: some View {
        panelContent
            .padding(placement.contentPadding)
            .clipVaultGlassSurface(
                cornerRadius: ClipVaultDesign.panelRadius,
                tint: model.aiAvailability.isAvailable ? .accentColor.opacity(0.05) : .orange.opacity(0.08)
            )
            .clipVaultPanelShadow(active: placement.showsShadow)
            .padding(placement.outerPadding)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch placement {
        case .inspector:
            inspectorLayout
        case .inline:
            inlineLayout
        }
    }

    private var inspectorLayout: some View {
        VStack(alignment: .leading, spacing: placement.verticalSpacing) {
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
                .frame(minHeight: placement.resultMinimumHeight, alignment: .topLeading)

            Spacer(minLength: 0)
        }
    }

    private var inlineLayout: some View {
        VStack(alignment: .leading, spacing: placement.verticalSpacing) {
            header

            resultArea
                .frame(
                    maxWidth: .infinity,
                    minHeight: placement.resultMinimumHeight,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )

            Divider()

            inlineControls
        }
    }

    private var actionGrid: some View {
        ClipVaultGlassContainer(spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: placement.actionMinimumWidth), spacing: 8)], alignment: .leading, spacing: 8) {
                actionButtons
            }
        }
    }

    private var inlineControls: some View {
        HStack(spacing: 8) {
            ClipVaultGlassContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(AIActionKind.allCases.filter { $0 != .ask }, id: \.self) { action in
                        compactActionButton(for: action)
                    }
                }
            }

            askRow
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(AIActionKind.allCases.filter { $0 != .ask }, id: \.self) { action in
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
                .frame(width: 32, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .clipVaultGlassSurface(cornerRadius: 8, tint: tint.opacity(0.12), interactive: true)
        .opacity(model.isGenerating ? 0.55 : 1)
        .disabled(model.isGenerating)
        .help(model.isGenerating ? "Wait for the current AI action to finish" : actionHelp(for: action))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(action.title))
        .accessibilityHint(Text(ClipVaultDesign.hint(for: action)))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Workspace")
                    .font(.headline)
                Text(availabilityText)
                    .font(.caption)
                    .foregroundStyle(model.aiAvailability.isAvailable ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            availabilityBadge
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        Group {
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
                            Text("\(result.citedClipIDs.count) clips cited")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(model.selectedClips.count) clips selected", systemImage: "checkmark.circle")
                        .font(.callout)
                    Text("Actions use the selected set, or the open clip when nothing is selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipVaultGlassSurface(cornerRadius: ClipVaultDesign.sectionRadius)
    }

    private var availabilityText: String {
        if model.aiAvailability.isAvailable {
            return "Foundation Models ready"
        }
        return model.aiAvailability.reason ?? "AI unavailable"
    }

    private var askRow: some View {
        HStack(spacing: 8) {
            TextField("Ask selected clips", text: $model.question)
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

    private var availabilityBadge: some View {
        Label(model.aiAvailability.isAvailable ? "Ready" : "Local fallback", systemImage: model.aiAvailability.isAvailable ? "sparkles" : "exclamationmark.triangle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(model.aiAvailability.isAvailable ? Color.accentColor : Color.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, placement.badgeHorizontalPadding)
            .padding(.vertical, 5)
            .clipVaultGlassCapsule(tint: model.aiAvailability.isAvailable ? .accentColor.opacity(0.10) : .orange.opacity(0.10))
            .help(availabilityText)
    }
}

enum AIActionPanelPlacement {
    case inspector
    case inline

    var contentPadding: CGFloat {
        switch self {
        case .inspector: 18
        case .inline: 12
        }
    }

    var outerPadding: CGFloat {
        switch self {
        case .inspector: 10
        case .inline: 6
        }
    }

    var verticalSpacing: CGFloat {
        switch self {
        case .inspector: 16
        case .inline: 12
        }
    }

    var actionMinimumWidth: CGFloat {
        switch self {
        case .inspector: 106
        case .inline: 92
        }
    }

    var askMinimumWidth: CGFloat {
        switch self {
        case .inspector: 180
        case .inline: 160
        }
    }

    var badgeHorizontalPadding: CGFloat {
        switch self {
        case .inspector: 9
        case .inline: 7
        }
    }

    var showsShadow: Bool {
        switch self {
        case .inspector: true
        case .inline: false
        }
    }

    var resultMinimumHeight: CGFloat {
        switch self {
        case .inspector: 120
        case .inline: 120
        }
    }
}
