import SwiftUI

struct ClipVaultGlassContainer<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

extension View {
    @ViewBuilder
    func clipVaultGlassSurface(
        cornerRadius: CGFloat = 12,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        background(
            (tint ?? Color.clear).opacity(interactive ? 0.10 : 0.07),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(interactive ? 0.18 : 0.11), lineWidth: 1)
        }
    }

    @ViewBuilder
    func clipVaultGlassCapsule(
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        background((tint ?? Color.clear).opacity(interactive ? 0.10 : 0.07), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(interactive ? 0.18 : 0.11), lineWidth: 1)
            }
    }

    @ViewBuilder
    func clipVaultGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }

    func clipVaultPanelShadow(active: Bool = true) -> some View {
        shadow(color: .black.opacity(active ? 0.12 : 0), radius: active ? 18 : 0, y: active ? 10 : 0)
    }
}
