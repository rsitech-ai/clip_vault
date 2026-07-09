import AppKit
import ClipVaultCore
import SwiftUI

struct SponsorButton: View {
    var title = "Sponsor"
    var action: @MainActor () -> Void = Self.openSponsorPage

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "heart.fill")
        }
        .help("Open the fixed Buy Me a Coffee sponsor page in your browser")
        .accessibilityHint("Opens the fixed Buy Me a Coffee sponsor page in your browser.")
    }

    @MainActor
    static func openSponsorPage() {
        if !NSWorkspace.shared.open(ClipVaultSupport.buyMeACoffeeURL) {
            NSSound.beep()
        }
    }
}
