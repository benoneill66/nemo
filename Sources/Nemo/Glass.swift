import SwiftUI
import AppKit

// MARK: - Window vibrancy

/// Real macOS vibrancy behind the SwiftUI content so `.ultraThinMaterial` cards have
/// something rich to refract — the foundation of the glassmorphic look.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

// MARK: - Aurora backdrop

/// Soft, slowly drifting colored blobs that sit beneath the glass and give it depth.
struct AuroraBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hue: 0.62, saturation: 0.55, brightness: 0.18),
                                    Color(hue: 0.74, saturation: 0.5, brightness: 0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            blob(hue: 0.58, size: 460)
                .offset(x: animate ? -150 : -90, y: animate ? -180 : -120)
            blob(hue: 0.82, size: 420)
                .offset(x: animate ? 180 : 120, y: animate ? -60 : -20)
            blob(hue: 0.50, size: 380)
                .offset(x: animate ? 60 : 120, y: animate ? 200 : 160)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }

    private func blob(hue: Double, size: CGFloat) -> some View {
        Circle()
            .fill(Color(hue: hue, saturation: 0.8, brightness: 0.9))
            .frame(width: size, height: size)
            .blur(radius: 90)
            .opacity(0.45)
    }
}

// MARK: - Glass card

/// The signature frosted panel: translucent material, a luminous hairline border, and a
/// soft drop shadow. Optionally tinted by a category hue.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 18
    var tintHue: Double? = nil
    var strong: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(strong ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial))
                    if let hue = tintHue {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(hue: hue, saturation: 0.7, brightness: 1).opacity(0.14))
                    }
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(colors: [.white.opacity(0.18), .clear],
                                           startPoint: .top, endPoint: .bottom)
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 18, tintHue: Double? = nil, strong: Bool = false) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, tintHue: tintHue, strong: strong))
    }
}

// MARK: - Small glass pieces

/// A frosted pill used for tags, categories, and counts.
struct GlassPill: View {
    var text: String
    var systemImage: String? = nil
    var hue: Double? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(
            Capsule().fill(hue.map { Color(hue: $0, saturation: 0.7, brightness: 1).opacity(0.22) } ?? Color.white.opacity(0.1))
        )
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .foregroundStyle(.white.opacity(0.92))
    }
}

/// A frosted, glowing action button.
struct GlassButton: View {
    var title: String
    var systemImage: String
    var prominent: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(LinearGradient(colors: [Color(hue: 0.6, saturation: 0.7, brightness: 1),
                                                                            Color(hue: 0.74, saturation: 0.7, brightness: 0.95)],
                                                                   startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(.ultraThinMaterial))
            )
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
