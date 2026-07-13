import AppKit
import ClipVaultCore
import CoreGraphics
import SwiftUI

struct SettingsView: View {
    @Bindable var model: ClipVaultViewModel
    var openWorkspace: () -> Void
    @AppStorage(ClipVaultSettingsKey.ordinaryClipRetentionDays) private var retentionDays = ClipVaultSettingsDefault.ordinaryClipRetentionDays
    @AppStorage(ClipVaultSettingsKey.cloudAIEnabled) private var cloudAIEnabled = ClipVaultSettingsDefault.cloudAIEnabled
    @AppStorage(ClipVaultSettingsKey.dockBadgeEnabled) private var dockBadgeEnabled = ClipVaultSettingsDefault.dockBadgeEnabled
    @AppStorage(ClipVaultSettingsKey.dockAnimationEnabled) private var dockAnimationEnabled = ClipVaultSettingsDefault.dockAnimationEnabled
    @AppStorage(ClipVaultSettingsKey.dockKindBarsEnabled) private var dockKindBarsEnabled = ClipVaultSettingsDefault.dockKindBarsEnabled
    @AppStorage(ClipVaultSettingsKey.dockRecentClipLimit) private var dockRecentClipLimit = ClipVaultSettingsDefault.dockRecentClipLimit
    @AppStorage(ClipVaultSettingsKey.liveNotchEnabled) private var liveNotchEnabled = ClipVaultSettingsDefault.liveNotchEnabled

    var body: some View {
        TabView {
            GeneralSettingsTab(model: model, openWorkspace: openWorkspace)
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

            PrivacyAccessSettingsTab()
                .tabItem {
                    Label("Access", systemImage: "checkmark.shield")
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
                dockRecentClipLimit: $dockRecentClipLimit,
                liveNotchEnabled: $liveNotchEnabled
            )
            .tabItem {
                Label("Surfaces", systemImage: "dock.rectangle")
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
        .onChange(of: liveNotchEnabled) { model.refreshLiveNotchPreferences() }
        .onAppear {
            recoverClipVaultWindows(after: 0.05)
            recoverClipVaultWindows(after: 0.3)
        }
    }
}

private struct GeneralSettingsTab: View {
    @Bindable var model: ClipVaultViewModel
    var openWorkspace: () -> Void
    @State private var confirmConsentRevocation = false

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Capture") {
                    Label(model.captureStateTitle, systemImage: model.isCapturing ? "checkmark.circle.fill" : "pause.circle")
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
                    set: { newValue in
                        guard newValue != model.isCapturing else {
                            return
                        }
                        model.toggleCapture()
                        if model.isCaptureConsentDisclosurePresented {
                            openWorkspace()
                        }
                    }
                ))
                .help(model.isCapturing ? "Pause clipboard capture" : "Start clipboard capture")

                Text("When capture is paused, existing clips remain searchable and copyable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.hasCaptureConsent {
                    Button("Revoke Clipboard Capture Consent", role: .destructive) {
                        confirmConsentRevocation = true
                    }
                    .help("Stop capture and require the disclosure before capture can be enabled again")
                } else {
                    Label("Capture remains off until you enable it from the disclosure.", systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Workspace") {
                LabeledContent("Open workspace shortcut", value: "Command-Shift-V")
                LabeledContent("Capture screenshot shortcut", value: "Command-Shift-2")
                LabeledContent("Menu bar behavior", value: "Click a clip to copy it")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Revoke Clipboard Capture Consent?",
            isPresented: $confirmConsentRevocation,
            titleVisibility: .visible
        ) {
            Button("Revoke Consent", role: .destructive) {
                model.revokeCaptureConsent()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clipboard capture will stop. To resume, you must accept the capture disclosure again.")
        }
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
                Label("Command-Shift-2 opens custom area or window screenshot capture.", systemImage: "camera.viewfinder")
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

private struct PrivacyAccessSettingsTab: View {
    @State private var screenCaptureAllowed = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section("Local Privacy") {
                Label("Clipboard payloads are encrypted locally with a keychain-backed key.", systemImage: "key")
                Label("Obvious secrets are excluded before storage and indexing.", systemImage: "lock.shield")
                Label("Cloud AI providers are disabled until explicit opt-in configuration exists.", systemImage: "icloud.slash")

                DisclosureGroup("Privacy Policy") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ClipVault does not collect, track, sell, or transmit personal data to the developer or third parties.")
                        Text("Clipboard items, screenshots, OCR text, titles, tags, notes, folders, source-application names, clipboard types, organization state, and settings stay on this Mac. Clipboard payloads, source context, and clip details are encrypted with a Keychain-backed key. Identifiers, kind, timestamps, deduplication fingerprints, copy counts, folder names, pin state, collection membership, and settings remain plaintext local metadata inside ClipVault's sandbox.")
                        Text("Ordinary clips are retained for 30 days by default. You can change retention, delete clips, pause capture, or revoke clipboard consent at any time.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }

            Section("Permissions") {
                PermissionStatusRow(
                    title: "Clipboard capture",
                    detail: "Available while ClipVault is running; no extra System Settings grant is required.",
                    state: .ready
                )
                PermissionStatusRow(
                    title: "Screenshot capture",
                    detail: screenCaptureAllowed
                        ? "Screen Recording is allowed for screenshot capture."
                        : "macOS may ask for Screen Recording the first time Shot is used.",
                    state: screenCaptureAllowed ? .ready : .needsReview
                )
                PermissionStatusRow(
                    title: "Local encryption key",
                    detail: "Stored in Keychain and used only for ClipVault's encrypted local payloads.",
                    state: .ready
                )
                PermissionStatusRow(
                    title: "User-selected files",
                    detail: "Read-only sandbox entitlement is included for files the user explicitly selects.",
                    state: .ready
                )
            }

            Section("Not Required") {
                PermissionStatusRow(
                    title: "Accessibility",
                    detail: "Not required for normal capture, search, copy, or Settings workflows.",
                    state: .notRequired
                )
                PermissionStatusRow(
                    title: "Full Disk Access",
                    detail: "Not required; ClipVault stores its own data in the app container.",
                    state: .notRequired
                )
                PermissionStatusRow(
                    title: "Cloud uploads",
                    detail: "Disabled; local AI is preferred and cloud providers remain off.",
                    state: .notRequired
                )
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

            Section("System Settings") {
                Button {
                    screenCaptureAllowed = CGPreflightScreenCaptureAccess()
                } label: {
                    Label("Check Screen Recording", systemImage: "arrow.clockwise")
                }

                Button {
                    openScreenRecordingSettings()
                } label: {
                    Label("Open Screen Recording Settings", systemImage: "gearshape")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
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
                ForEach([AIActionKind.summarize, .explain, .todos, .ask], id: \.self) { action in
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
    @Binding var liveNotchEnabled: Bool

    var body: some View {
        Form {
            Section("Live Notch") {
                Toggle("Show Live Notch on hover", isOn: $liveNotchEnabled)
                    .help("Show ClipVault's live activity panel when the pointer enters the top-center notch area")

                Text("The Live Notch stays hidden until you hover the top-center menu bar area, then fades away when you leave.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dock Tile") {
                Toggle("Show clip count badge", isOn: $dockBadgeEnabled)
                Toggle("Animate Dock tile while capturing", isOn: $dockAnimationEnabled)
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
                Label("Complete App Store Connect metadata, upload validation, and review before delivery.", systemImage: "shippingbox")
                    .foregroundStyle(.secondary)
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

private enum PermissionStatusState {
    case ready
    case needsReview
    case notRequired

    var label: String {
        switch self {
        case .ready: "Ready"
        case .needsReview: "Check"
        case .notRequired: "Not required"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .needsReview: "exclamationmark.triangle.fill"
        case .notRequired: "minus.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .green
        case .needsReview: .orange
        case .notRequired: .secondary
        }
    }
}

private struct PermissionStatusRow: View {
    var title: String
    var detail: String
    var state: PermissionStatusState

    var body: some View {
        LabeledContent {
            Label(state.label, systemImage: state.systemImage)
                .foregroundStyle(state.tint)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
