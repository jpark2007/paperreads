import SwiftUI
import AppKit

// Design tokens — docs/ARCHITECTURE.md §1 "Editorial Minimal". Mirrored in Web/common.css.
// Every surface is the same off-white paper; regions are separated by 1px hairlines only.
// No cards, no shadows, no gradients. The clay accent is reserved for live states
// (streaming, focus, drop targets, in-progress imports) and highlight marks.

enum Theme {
    // MARK: Colour
    static let bg = Color(nsColor: nsBg)
    static let ink = Color(nsColor: nsInk)
    static let muted = rgb(0x565145)
    static let faint = rgb(0x7d7669)
    static let hairline = Color(.sRGB, red: 33 / 255, green: 29 / 255, blue: 23 / 255, opacity: 0.12)
    static let accent = Color(nsColor: nsAccent)
    static let accentText = rgb(0xb04f2f)
    static let highlightFill = Color(.sRGB, red: 217 / 255, green: 119 / 255, blue: 87 / 255, opacity: 0.22)
    static let danger = rgb(0xc4472f)
    /// Quiet selection tint for list rows (ink at very low alpha — not a card).
    static let selection = Color(.sRGB, red: 33 / 255, green: 29 / 255, blue: 23 / 255, opacity: 0.055)

    static let nsBg = nsRGB(0xf2efe6)
    static let nsInk = nsRGB(0x211d17)
    static let nsMuted = nsRGB(0x565145)
    static let nsFaint = nsRGB(0x7d7669)
    static let nsAccent = nsRGB(0xd97757)

    // MARK: Metrics
    /// 24 / 32 / 48 rhythm.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }
    static let pillRadius: CGFloat = 19
    static let outlineWidth: CGFloat = 1.5
    static let sidePanelWidth: CGFloat = 380

    // MARK: Helpers
    private static func rgb(_ hex: UInt32) -> Color {
        Color(nsColor: nsRGB(hex))
    }

    private static func nsRGB(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }

    /// SF Pro Rounded as an AppKit font (for NSTextView-backed inputs).
    static func nsRounded(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) {
            return f
        }
        return base
    }

    /// "claude-opus-5-5" → "Opus 5.5"
    static func modelDisplayName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }
}

// MARK: - Fonts

extension Font {
    /// New York — reading text and headings.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// SF Pro Rounded — UI chrome.
    static func rounded(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Modifiers

private struct CapsLabel: ViewModifier {
    var color: Color
    func body(content: Content) -> some View {
        content
            .font(.rounded(11, weight: .bold))
            .tracking(0.88)            // +0.08em at 11px
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

private struct OutlineControl: ViewModifier {
    var height: CGFloat
    func body(content: Content) -> some View {
        content
            .font(.rounded(13, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .frame(height: height)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous)
                    .strokeBorder(Theme.ink, lineWidth: Theme.outlineWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous))
    }
}

extension View {
    /// 11pt bold, +0.08em, uppercase, muted.
    func capsLabel(_ color: Color = Theme.muted) -> some View {
        modifier(CapsLabel(color: color))
    }

    /// Transparent pill with a 1.5px ink outline.
    func outlineControl(height: CGFloat = 30) -> some View {
        modifier(OutlineControl(height: height))
    }
}

// MARK: - Button styles

/// Outlined pill (primary controls). Never filled.
struct PillButtonStyle: ButtonStyle {
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, height: height)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .lineLimit(1)
                .outlineControl(height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous)
                        .fill(Theme.ink.opacity(hovering && isEnabled ? 0.045 : 0))
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.32)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Plain text button: muted at rest, ink on hover.
struct TextButtonStyle: ButtonStyle {
    var color: Color = Theme.muted
    var hoverColor: Color = Theme.ink
    var size: CGFloat = 13
    var weight: Font.Weight = .medium

    func makeBody(configuration: Configuration) -> some View {
        TextBody(configuration: configuration, color: color, hoverColor: hoverColor, size: size, weight: weight)
    }

    private struct TextBody: View {
        let configuration: ButtonStyleConfiguration
        let color: Color
        let hoverColor: Color
        let size: CGFloat
        let weight: Font.Weight
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.rounded(size, weight: weight))
                .foregroundStyle(hovering && isEnabled ? hoverColor : color)
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
}

extension ButtonStyle where Self == TextButtonStyle {
    static var text: TextButtonStyle { TextButtonStyle() }
}

// MARK: - Hairline

struct Hairline: View {
    var axis: Axis = .horizontal
    var body: some View {
        switch axis {
        case .horizontal: Rectangle().fill(Theme.hairline).frame(height: 1)
        case .vertical: Rectangle().fill(Theme.hairline).frame(width: 1)
        }
    }
}

/// Segmented text toggle inside an outlined pill, e.g. `Text | PDF`.
struct TextSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: 14)
                }
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.rounded(13, weight: selection == option.0 ? .semibold : .medium))
                        .foregroundStyle(selection == option.0 ? Theme.ink : Theme.faint)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous)
                .strokeBorder(Theme.ink, lineWidth: Theme.outlineWidth)
        )
        .fixedSize()
    }
}
