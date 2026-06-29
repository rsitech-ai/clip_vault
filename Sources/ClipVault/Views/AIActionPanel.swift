import ClipVaultCore
import SwiftUI

struct AIActionPanel: View {
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Workspace")
                    .font(.headline)
                Text(availabilityText)
                    .font(.caption)
                    .foregroundStyle(model.aiAvailability.isAvailable ? Color.secondary : Color.orange)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(AIActionKind.allCases.filter { $0 != .ask }, id: \.self) { action in
                    Button {
                        model.runAIAction(action)
                    } label: {
                        Text(action.title)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.isGenerating)
                    .help(model.isGenerating ? "Wait for the current AI action to finish" : action.title)
                }
            }
            .buttonStyle(.bordered)

            ViewThatFits(in: .horizontal) {
                askRow
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Ask selected clips", text: $model.question)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.runAIAction(.ask)
                    } label: {
                        Label("Ask", systemImage: "arrow.up.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.isGenerating)
                    .help(model.isGenerating ? "Wait for the current AI action to finish" : "Ask a question about the selected clips")
                }
            }

            Divider()

            if model.isGenerating {
                ProgressView("Thinking")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = model.aiError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
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
                    Text("\(model.selectedClips.count) clips selected")
                        .font(.callout)
                    Text("Actions use the selected set, or the open clip when nothing is selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(18)
        .background(.ultraThinMaterial)
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
                Label("Ask", systemImage: "arrow.up.circle.fill")
            }
            .disabled(model.isGenerating)
            .help(model.isGenerating ? "Wait for the current AI action to finish" : "Ask a question about the selected clips")
        }
    }
}
