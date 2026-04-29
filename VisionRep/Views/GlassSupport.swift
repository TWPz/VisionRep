import SwiftUI

struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    var isInteractive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    glass,
                    in: .rect(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        let base = Glass.regular.tint(tint)
        return isInteractive ? base.interactive() : base
    }
}

extension View {
    func visionGlassPanel(
        cornerRadius: CGFloat = 22,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius, tint: tint, isInteractive: interactive))
    }
}

struct GlassActionButton: View {
    var title: String
    var systemImage: String
    var isProminent = false
    var action: () -> Void

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            if isProminent {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.glass)
            }
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private var button: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .accessibilityLabel(title)
    }
}
