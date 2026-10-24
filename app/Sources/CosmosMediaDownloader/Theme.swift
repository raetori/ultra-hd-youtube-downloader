import SwiftUI

enum Theme {
    static let accent = Color(red: 0.49, green: 0.38, blue: 1.0)
    static let accentDeep = Color(red: 0.30, green: 0.20, blue: 0.85)
    /// Near-black like creationofcosmos.com, with a faint violet glow toward one corner.
    static let space = LinearGradient(colors: [Color(red: 0.0, green: 0.0, blue: 0.0), Color(red: 0.03, green: 0.03, blue: 0.05),
                                               Color(red: 0.09, green: 0.06, blue: 0.16)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)

    static func siteColor(_ site: String) -> Color {
        switch site {
        case "YouTube": return Color(red: 0.93, green: 0.18, blue: 0.18)
        case "TikTok": return Color(red: 0.0, green: 0.78, blue: 0.80)
        case "Instagram": return Color(red: 0.86, green: 0.20, blue: 0.55)
        case "Facebook": return Color(red: 0.10, green: 0.45, blue: 0.95)
        case "Vimeo": return Color(red: 0.10, green: 0.70, blue: 0.95)
        case "X": return Color.primary
        default: return Color.secondary
        }
    }
}

/// The Creation of Cosmos mark: an open ring with a dot, drawn from the brand SVG (100×100 viewBox).
struct CosmosMark: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let scale = size / 100
        let origin = CGPoint(x: rect.midX - size / 2, y: rect.midY - size / 2)
        func point(_ radius: Double, _ degrees: Double) -> CGPoint {
            let a = degrees * .pi / 180
            return CGPoint(x: origin.x + (50 + radius * cos(a)) * scale, y: origin.y + (50 + radius * sin(a)) * scale)
        }
        var path = Path()
        let angles = Array(stride(from: 42.0, through: 318.0, by: 2.0))
        path.move(to: point(44, angles[0]))
        for a in angles.dropFirst() { path.addLine(to: point(44, a)) }
        for a in angles.reversed() { path.addLine(to: point(29, a)) }
        path.closeSubpath()
        let dot = CGRect(x: origin.x + (80 - 9.5) * scale, y: origin.y + (50 - 9.5) * scale, width: 19 * scale, height: 19 * scale)
        path.addEllipse(in: dot)
        return path
    }
}

struct SiteBadge: View {
    let site: String

    var body: some View {
        if !site.isEmpty {
            Text(site)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(Theme.siteColor(site))
                .background(Capsule().fill(Theme.siteColor(site).opacity(0.14)))
        }
    }
}

struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(Capsule().strokeBorder(tint.opacity(0.35)))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .top, endPoint: .bottom))
                    .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            )
    }
}

/// A quiet field of stars behind the header. Positions come from a fixed seed so it never flickers.
struct Starfield: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(UInt64(1) << 31)
            }
            for _ in 0..<140 {
                let x = next() * size.width
                let y = next() * size.height
                let r = 0.4 + next() * 1.1
                let alpha = 0.15 + next() * 0.55
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
    }
}
