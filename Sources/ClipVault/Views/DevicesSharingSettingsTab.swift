import ClipVaultCore
import SwiftUI

struct DevicesSharingSettingsTab: View {
    @Bindable var sync: ClipVaultSyncController
    @State private var relay = ""
    @State private var registration = ""
    @State private var deviceName = "Mac laptop"
    @State private var invitation = ""
    @State private var disconnecting = false
    @State private var removal: ClipSyncMember?

    var body: some View {
        Form {
            Section("Encrypted device sharing") {
                Text("Pair your Mac and Ubuntu laptop to share new text and image clips. Content is encrypted before it leaves this device. Your relay can see timing, sizes and device identifiers. Existing history is shared only when you select it.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Enable sharing with paired devices", isOn: Binding(get: { sync.status.enabled }, set: sync.setEnabled))
                LabeledContent("Status", value: sync.status.state)
                Button("Disconnect and reset pairing…", role: .destructive) { disconnecting = true }
                    .disabled(sync.busy)
                if let message = sync.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                Text("Received clips appear in history. Use Copy to put one on this Mac’s clipboard. Notes, folders, pins and file references stay local.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if sync.status.members.isEmpty {
                Section("Set up your devices") {
                    TextField("This device name", text: $deviceName)
                    SecureField("Invitation from your other laptop", text: $invitation)
                    Button("Join paired devices") {
                        sync.join(code: invitation, name: deviceName); invitation = ""
                    }.disabled(invitation.isEmpty || sync.busy)
                    DisclosureGroup("Create a workspace on your own relay") {
                        TextField("Relay URL", text: $relay, prompt: Text("https://sync.example.com"))
                        SecureField("Relay provisioning secret", text: $registration)
                        Button("Create private workspace") {
                            sync.create(relay: relay, registration: registration, name: deviceName); registration = ""
                        }.disabled(relay.isEmpty || registration.isEmpty || sync.busy)
                    }
                }
            }
            if !sync.status.members.isEmpty {
                Section("Devices") {
                    ForEach(sync.status.members) { member in
                        HStack {
                            Text(member.id == sync.status.deviceID ? "This Mac" : "Paired device")
                            Spacer()
                            Text(String(member.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if sync.status.isOwner, member.id != sync.status.deviceID {
                                Button("Remove", role: .destructive) { removal = member }
                            }
                        }
                    }
                    if sync.status.isOwner {
                        Button("Add a device — create invitation", action: sync.invite).disabled(sync.busy || !sync.status.enabled)
                    }
                    Button("Share selected clip", action: sync.shareSelected)
                        .disabled(!sync.status.enabled || sync.status.members.count < 2 || sync.busy)
                }
            }
            ForEach(sync.status.requests) { request in
                Section("Device requests access") {
                    Text("Compare this verification code on both devices:").font(.callout)
                    Text(request.words).font(.body.monospaced()).textSelection(.enabled)
                    Button("Codes match — approve device") { sync.approve(request) }.disabled(sync.busy || !sync.status.enabled)
                }
            }
            if let code = sync.pairingCode {
                Section(code.hasPrefix("clipvault-pair-v1:") ? "Private invitation — expires in ten minutes" : "Compare on the owner device") {
                    Text(code).font(.caption.monospaced()).textSelection(.enabled).lineLimit(5)
                    Button("Copy invitation", action: sync.copyInvitation)
                    Button("Dismiss invitation") { sync.pairingCode = nil }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Disconnect this device?", isPresented: $disconnecting) {
            Button("Disconnect and keep local history", role: .destructive, action: sync.disconnect)
        } message: {
            Text("Pending shares are cancelled and local pairing keys are replaced. History stays on this Mac. Remove this device on the owner to revoke its old membership. Disconnecting an owner also loses administration of that workspace; create a new workspace to pair again.")
        }
        .confirmationDialog("Remove this device?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Remove device", role: .destructive) { if let removal { sync.remove(id: removal.id) }; removal = nil }.disabled(!sync.status.enabled)
        } message: {
            Text("New clips will stop being sent to it. Clips already received remain on that device.")
        }
    }
}
