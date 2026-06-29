import SwiftUI

struct SettingsView: View {
    @Bindable var model: ClipVaultViewModel
    @AppStorage("ordinaryClipRetentionDays") private var retentionDays = 30
    @AppStorage("cloudAIEnabled") private var cloudAIEnabled = false

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("Clipboard capture", isOn: Binding(
                    get: { model.isCapturing },
                    set: { _ in model.toggleCapture() }
                ))
                Stepper("Retention: \(retentionDays) days", value: $retentionDays, in: 7...180, step: 1)
            }

            Section("Privacy") {
                Label("Sensitive-looking clips are excluded before storage and indexing.", systemImage: "lock.shield")
                Label("Stored clip payloads use local keychain-backed encryption.", systemImage: "key")
            }

            Section("AI") {
                Label(model.aiAvailability.reason ?? "Foundation Models ready", systemImage: model.aiAvailability.isAvailable ? "sparkles" : "exclamationmark.triangle")
                Toggle("Cloud AI providers", isOn: $cloudAIEnabled)
                    .disabled(true)
                    .help("Cloud AI providers are disabled until explicit opt-in configuration exists")
                Text("Cloud providers are disabled until explicit opt-in configuration exists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
