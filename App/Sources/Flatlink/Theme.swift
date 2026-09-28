import SwiftUI

/// The README's palette: a Prussian blue card, white for original photos, marigold for links.
extension Color {
    static let prussianDeep = Color(red: 0x0A / 255, green: 0x24 / 255, blue: 0x38 / 255)
    static let prussianMid = Color(red: 0x0D / 255, green: 0x36 / 255, blue: 0x54 / 255)
    static let prussian = Color(red: 0x15 / 255, green: 0x51 / 255, blue: 0x78 / 255)
    static let marigold = Color(red: 0xE8 / 255, green: 0x9E / 255, blue: 0x29 / 255)
    static let paleBlue = Color(red: 0xBF / 255, green: 0xDD / 255, blue: 0xF2 / 255)
}

extension ShapeStyle where Self == LinearGradient {
    static var card: LinearGradient {
        LinearGradient(colors: [.prussianDeep, .prussianMid, .prussian], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Marigold with Prussian text: white on marigold is too faint to read.
struct MarigoldButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.prussianDeep)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.marigold.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A quiet outlined button for use on the card.
struct CardButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.08), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.35)))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension Font {
    static let wordmark = Font.system(size: 34, weight: .bold, design: .monospaced)
    static let path = Font.system(.callout, design: .monospaced)
}
