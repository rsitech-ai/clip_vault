import AppKit
import ClipVaultCore
import SwiftUI

struct SponsorButton: View {
    var title = "Sponsor"

    var body: some View {
        Button {
            if !NSWorkspace.shared.open(ClipVaultSupport.buyMeACoffeeURL) {
                NSSound.beep()
            }
        } label: {
            Label(title, systemImage: "heart.fill")
        }
        .help("Open the fixed Buy Me a Coffee sponsor page in your browser")
        .accessibilityHint("Opens the fixed Buy Me a Coffee sponsor page in your browser.")
    }
}
