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
        if #available(macOS 26.0, *) {
            if let tint {
                if interactive {
                    glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
                } else {
                    glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
                }
            } else if interactive {
                glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func clipVaultGlassCapsule(
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                if interactive {
                    glassEffect(.regular.tint(tint).interactive(), in: .capsule)
                } else {
                    glassEffect(.regular.tint(tint), in: .capsule)
                }
            } else if interactive {
                glassEffect(.regular.interactive(), in: .capsule)
            } else {
                glassEffect(.regular, in: .capsule)
            }
        } else {
            background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
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
