import SwiftUI

/// Liquid Glass is reserved for floating chrome (mini-player, player controls, chips, banners,
/// tab bar). Content cards never use it.
struct GlassPanel<Content: View>: View {
  var cornerRadius: CGFloat = 20
  @ViewBuilder var content: Content
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    if reduceTransparency {
      content
        .background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color(.separator), lineWidth: 1))
    } else {
      content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
  }
}

private struct GlassControlModifier: ViewModifier {
  var interactive: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
    } else {
      content.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
    }
  }
}

extension View {
  /// Capsule glass for floating controls; opaque material when Reduce Transparency is on.
  func glassControl(interactive: Bool = true) -> some View {
    modifier(GlassControlModifier(interactive: interactive))
  }
}

/// Transient toast used for SponsorBlock skips, double-tap seeks and errors.
struct GlassToast<Trailing: View>: View {
  let text: String
  var systemImage: String?
  /// Tints the icon (SponsorBlock category colour).
  var accent: Color?
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 10) {
      if let systemImage { Image(systemName: systemImage).foregroundStyle(accent ?? .primary) }
      Text(text).font(.subheadline.weight(.medium)).lineLimit(2)
      trailing
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .glassControl(interactive: false)
  }
}

extension GlassToast where Trailing == EmptyView {
  init(text: String, systemImage: String? = nil, accent: Color? = nil) {
    self.init(text: text, systemImage: systemImage, accent: accent) { EmptyView() }
  }
}
