import ClipVaultCore
import SwiftUI

struct AIActionPanel: View {
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ClipVaultGlassContainer(spacing: 10) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 106), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(AIActionKind.allCases.filter { $0 != .ask }, id: \.self) { action in
                        Button {
                            model.runAIAction(action)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: ClipVaultDesign.icon(for: action))
                                Text(action.title)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                        }
                        .clipVaultGlassButtonStyle()
                        .disabled(model.isGenerating)
                        .help(model.isGenerating ? "Wait for the current AI action to finish" : action.title)
                    }
                }
            }

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
                    .disabled(model.isGenerating)
                    .help(model.isGenerating ? "Wait for the current AI action to finish" : "Ask a question about the selected clips")
                }
            }

            Divider()

            resultArea

            Spacer(minLength: 0)
        }
        .padding(18)
        .clipVaultGlassSurface(
            cornerRadius: ClipVaultDesign.panelRadius,
            tint: model.aiAvailability.isAvailable ? .accentColor.opacity(0.05) : .orange.opacity(0.08)
        )
        .clipVaultPanelShadow()
        .padding(10)
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

            Label(model.aiAvailability.isAvailable ? "Ready" : "Local fallback", systemImage: model.aiAvailability.isAvailable ? "sparkles" : "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.aiAvailability.isAvailable ? Color.accentColor : Color.orange)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .clipVaultGlassCapsule(tint: model.aiAvailability.isAvailable ? .accentColor.opacity(0.10) : .orange.opacity(0.10))
                .help(availabilityText)
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
                        Text(result.title)
                            .font(.headline)
                        Text(result.content)
                            .textSelection(.enabled)
                        if !result.citedClipIDs.isEmpty {
                            Text("\(result.citedClipIDs.count) clips cited")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipVaultGlassSurface(cornerRadius: ClipVaultDesign.sectionRadius)
    }

    private var availabilityText: String {
        if model.aiAvailability.isAvailable {
            return "Foundation Models ready"
        }
        return model.aiAvailability.reason ?? "AI unavailable"
    }

    private var askRow: some View {
        HStack {
            TextField("Ask selected clips", text: $model.question)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)
            Button {
                model.runAIAction(.ask)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: ClipVaultDesign.icon(for: .ask))
                    Text("Ask")
                }
                .font(.caption.weight(.semibold))
            }
            .clipVaultGlassButtonStyle(prominent: true)
            .disabled(model.isGenerating)
            .help(model.isGenerating ? "Wait for the current AI action to finish" : "Ask a question about the selected clips")
        }
    }
}
