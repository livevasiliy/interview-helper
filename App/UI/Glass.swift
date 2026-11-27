import SwiftUI

// Liquid Glass (macOS 26+) for the floating, functional layer only: the overlay's header buttons and the
// typed-question field. The answer text and the Setup/Settings forms are content, which stays on standard
// materials; the system already gives windows, tabs, toggles and pickers their glass when the app is built
// with the macOS 26 SDK. Before macOS 26 every helper falls back to the previous look, because the
// deployment target is macOS 13.

extension View {
    /// A glass surface in `shape` on macOS 26+, a subtle fill before it.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(Color.primary.opacity(0.08), in: shape)
        }
    }

    /// An icon (or icon + caption) button. On macOS 26+ it is an interactive glass circle or capsule of our own
    /// size (the system `.glass` style is wider and would push the captions out of the header); before it, the
    /// plain secondary-colored button.
    @ViewBuilder
    func glassButtonStyle(circular: Bool) -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.plain)
                .padding(.horizontal, circular ? 0 : 9)
                .padding(.vertical, circular ? 0 : 3)
                .glassEffect(.regular.interactive(), in: circular ? AnyShape(Circle()) : AnyShape(Capsule()))
        } else {
            buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    /// The primary action: prominent glass on macOS 26+, the usual prominent style before it.
    @ViewBuilder
    func prominentGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// Neighbouring glass elements share one container so they render and blend together (glass cannot
/// sample other glass). On older systems it is a transparent pass-through.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
