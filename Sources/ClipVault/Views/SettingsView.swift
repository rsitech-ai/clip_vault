import ClipVaultCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: ClipVaultViewModel
    @AppStorage(ClipVaultSettingsKey.ordinaryClipRetentionDays) private var retentionDays = ClipVaultSettingsDefault.ordinaryClipRetentionDays
    @AppStorage(ClipVaultSettingsKey.cloudAIEnabled) private var cloudAIEnabled = ClipVaultSettingsDefault.cloudAIEnabled
    @AppStorage(ClipVaultSettingsKey.dockBadgeEnabled) private var dockBadgeEnabled = ClipVaultSettingsDefault.dockBadgeEnabled
    @AppStorage(ClipVaultSettingsKey.dockAnimationEnabled) private var dockAnimationEnabled = ClipVaultSettingsDefault.dockAnimationEnabled
    @AppStorage(ClipVaultSettingsKey.dockKindBarsEnabled) private var dockKindBarsEnabled = ClipVaultSettingsDefault.dockKindBarsEnabled
    @AppStorage(ClipVaultSettingsKey.dockRecentClipLimit) private var dockRecentClipLimit = ClipVaultSettingsDefault.dockRecentClipLimit

    var body: some View {
        TabView {
            GeneralSettingsTab(model: model)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            CaptureStorageSettingsTab(
                model: model,
                retentionDays: $retentionDays
            )
            .tabItem {
                Label("Capture", systemImage: "doc.on.clipboard")
            }

            PrivacySettingsTab()
                .tabItem {
                    Label("Privacy", systemImage: "lock.shield")
                }

            AISettingsTab(
                model: model,
                cloudAIEnabled: $cloudAIEnabled
            )
            .tabItem {
                Label("AI", systemImage: "sparkles")
            }

            DockSettingsTab(
                dockBadgeEnabled: $dockBadgeEnabled,
                dockAnimationEnabled: $dockAnimationEnabled,
                dockKindBarsEnabled: $dockKindBarsEnabled,
                dockRecentClipLimit: $dockRecentClipLimit
            )
            .tabItem {
                Label("Dock", systemImage: "dock.rectangle")
            }

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 620, height: 460)
        .scenePadding()
        .onChange(of: dockBadgeEnabled) { model.refreshDockTilePreferences() }
        .onChange(of: dockAnimationEnabled) { model.refreshDockTilePreferences() }
        .onChange(of: dockKindBarsEnabled) { model.refreshDockTilePreferences() }
        .onChange(of: dockRecentClipLimit) { model.refreshDockTilePreferences() }
    }
}

private struct GeneralSettingsTab: View {
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Capture") {
                    Label(model.isCapturing ? "Watching clipboard" : "Paused", systemImage: model.isCapturing ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundStyle(model.isCapturing ? .green : .secondary)
                }
                LabeledContent("Indexed clips", value: "\(model.clips.count)")
                if let storageStartupError = model.storageStartupError {
                    Label(storageStartupError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Capture") {
                Toggle("Clipboard capture", isOn: Binding(
                    get: { model.isCapturing },
                    set: { _ in model.toggleCapture() }
                ))
                .help(model.isCapturing ? "Pause clipboard capture" : "Start clipboard capture")

                Text("When capture is paused, existing clips remain searchable and copyable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Workspace") {
                LabeledContent("Open workspace shortcut", value: "Command-Shift-V")
                LabeledContent("Menu bar behavior", value: "Click a clip to copy it")
            }
        }
        .formStyle(.grouped)
    }
}

private struct CaptureStorageSettingsTab: View {
    @Bindable var model: ClipVaultViewModel
    @Binding var retentionDays: Int

    var body: some View {
        Form {
            Section("Retention") {
                Stepper(value: $retentionDays, in: 7...180, step: 1) {
                    LabeledContent("Ordinary clips", value: "\(retentionDays) days")
                }

                Button {
                    model.pruneExpiredClips(retentionDays: retentionDays)
                } label: {
                    Label("Apply Retention Cleanup Now", systemImage: "clock.arrow.circlepath")
                }
                .help("Remove unpinned clips older than the selected retention window")

                Text("Pinned clips and clips saved to boards are kept until you remove them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Total clips", value: "\(model.clips.count)")
                LabeledContent("Pinned clips", value: "\(model.clips.filter(\.isPinned).count)")
                LabeledContent("Image clips", value: "\(model.clips.filter { $0.kind == .image }.count)")
                LabeledContent("Duplicate groups", value: "\(duplicateGroupCount)")
            }

            Section("Capture Intelligence") {
                Label("Text, URLs, rich text, files, and images are captured when present.", systemImage: "tray.and.arrow.down")
                Label("Image text is recognized locally with Vision OCR.", systemImage: "text.viewfinder")
                Label("Code, SQL, errors, links, images, and files are grouped into smart collections.", systemImage: "folder.badge.gearshape")
            }
        }
        .formStyle(.grouped)
    }

    private var duplicateGroupCount: Int {
        Dictionary(grouping: model.clips, by: \.fingerprint)
            .filter { $0.value.count > 1 || ($0.value.first?.copyCount ?? 1) > 1 }
            .count
    }
}

private struct PrivacySettingsTab: View {
    var body: some View {
        Form {
            Section("Local Privacy") {
                Label("Clipboard payloads are encrypted locally with a keychain-backed key.", systemImage: "key")
                Label("Obvious secrets are excluded before storage and indexing.", systemImage: "lock.shield")
                Label("Cloud AI providers are disabled until explicit opt-in configuration exists.", systemImage: "icloud.slash")
            }

            Section("Sensitive Exclusion") {
                LabeledContent("Private keys", value: "Excluded")
                LabeledContent("Common API tokens", value: "Excluded")
                LabeledContent("Password-like assignments", value: "Excluded")
                LabeledContent("Harmless code snippets", value: "Kept")
            }

            Section("Review Notes") {
                Text("ClipVault is designed to process clipboard content on device. Review privacy labels before enabling any future sync, team, or cloud AI feature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AISettingsTab: View {
    @Bindable var model: ClipVaultViewModel
    @Binding var cloudAIEnabled: Bool

    var body: some View {
        Form {
            Section("Local AI") {
                Label(
                    model.aiAvailability.reason ?? "Foundation Models ready",
                    systemImage: model.aiAvailability.isAvailable ? "sparkles" : "exclamationmark.triangle"
                )
                .foregroundStyle(model.aiAvailability.isAvailable ? Color.secondary : Color.orange)

                Text("Selected-clip actions use Foundation Models when available and fall back to local deterministic summaries when unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Providers") {
                Toggle("Cloud AI providers", isOn: $cloudAIEnabled)
                    .disabled(true)
                    .help("Cloud AI providers are disabled until explicit opt-in configuration exists")

                LabeledContent("Default provider", value: "Apple local when available")
                LabeledContent("Clipboard upload", value: "Disabled")
            }

            Section("Actions") {
                ForEach(AIActionKind.allCases, id: \.self) { action in
                    Label(action.title, systemImage: icon(for: action))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func icon(for action: AIActionKind) -> String {
        switch action {
        case .summarize: "text.alignleft"
        case .explain: "questionmark.bubble"
        case .email: "envelope"
        case .todos: "checklist"
        case .ask: "arrow.up.circle"
        }
    }
}

private struct DockSettingsTab: View {
    @Binding var dockBadgeEnabled: Bool
    @Binding var dockAnimationEnabled: Bool
    @Binding var dockKindBarsEnabled: Bool
    @Binding var dockRecentClipLimit: Int

    var body: some View {
        Form {
            Section("Dock Tile") {
                Toggle("Show clip count badge", isOn: $dockBadgeEnabled)
                Toggle("Animate while capturing", isOn: $dockAnimationEnabled)
                Toggle("Show recent clip type colors", isOn: $dockKindBarsEnabled)

                Text("Dock changes apply immediately to the running app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dock Menu") {
                Stepper(value: $dockRecentClipLimit, in: 3...10, step: 1) {
                    LabeledContent("Recent clips", value: "\(dockRecentClipLimit)")
                }

                Text("The Dock menu can open ClipVault, pause capture, and copy recent clips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettingsTab: View {
    var body: some View {
        Form {
            Section("ClipVault") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: appBuild)
                LabeledContent("Bundle ID", value: bundleID)
                LabeledContent("Category", value: "Productivity")
            }

            Section("Release Readiness") {
                Label("Sandbox entitlement and privacy manifest are included.", systemImage: "checkmark.seal")
                Label("Mac installer distribution certificate is still required for App Store upload.", systemImage: "shippingbox")
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.andrzej.ClipVault"
    }
}
