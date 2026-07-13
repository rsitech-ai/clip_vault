import SwiftUI

struct CaptureConsentView: View {
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Enable Clipboard Capture?", systemImage: "doc.on.clipboard")
                .font(.title2.bold())

            Text("ClipVault can watch copied text, images, links, and file references. Image text is recognized locally with OCR, and captured content is stored encrypted on this Mac.")

            VStack(alignment: .leading, spacing: 8) {
                Label("Ordinary clips are kept for 30 days by default; you can change retention in Settings.", systemImage: "clock")
                Label("Sensitive-item filtering excludes obvious secrets, but it may not recognize every password, token, or private detail.", systemImage: "exclamationmark.shield")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Button("Not Now") {
                    model.declineCaptureConsent()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Enable Clipboard Capture") {
                    model.acceptCaptureConsent()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }
}

extension View {
    func captureConsentDisclosure(model: ClipVaultViewModel) -> some View {
        sheet(
            isPresented: Binding(
                get: { model.isCaptureConsentDisclosurePresented },
                set: { isPresented in
                    if !isPresented {
                        model.declineCaptureConsent()
                    }
                }
            )
        ) {
            CaptureConsentView(model: model)
        }
    }
}
