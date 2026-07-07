import ClipVaultCore
import SwiftUI

struct ClipTimestampText: View {
    var date: Date

    var body: some View {
        Text(ClipTimeFormatter.relativeLabel(for: date))
    }
}
