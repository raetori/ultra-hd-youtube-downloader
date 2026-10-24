import SwiftUI

/// The look of creationofcosmos.com: deep-space black, warm gold light (the black hole's disk),
/// small ember mono labels, thin wide-tracked titles and soft, eased motion.
enum Theme {
    static let ink = Color(red: 0.020, green: 0.020, blue: 0.024)
    static let gold = Color(red: 0.93, green: 0.76, blue: 0.53)
    static let goldDeep = Color(red: 0.70, green: 0.46, blue: 0.24)
    static let ember = Color(red: 0.95, green: 0.56, blue: 0.30)
    static let cream = Color(red: 0.96, green: 0.93, blue: 0.87)
    static let danger = Color(red: 0.96, green: 0.46, blue: 0.40)
    static let accent = gold

    static let card = Color.white.opacity(0.035)
    static let hairline = Color.white.opacity(0.08)
    static let textDim = Color.white.opacity(0.55)

    /// Near-black with the faintest warm light rising from below, like the horizon on the site.
    static let space = LinearGradient(colors: [Color.black, Color(red: 0.03, green: 0.025, blue: 0.025),
                                               Color(red: 0.07, green: 0.05, blue: 0.035)],
                                      startPoint: .top, endPoint: .bottom)

    /// Every motion in the app uses this: smooth, soft, never snappy.
    static let ease = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.55)

    static func siteColor(_ site: String) -> Color {
        switch site {
        case "YouTube": return Color(red: 0.95, green: 0.38, blue: 0.36)
        case "TikTok": return Color(red: 0.35, green: 0.85, blue: 0.85)
        case "Instagram": return Color(red: 0.92, green: 0.45, blue: 0.68)
        case "Facebook": return Color(red: 0.45, green: 0.62, blue: 0.98)
        case "Vimeo": return Color(red: 0.40, green: 0.78, blue: 0.95)
        default: return Color.white.opacity(0.7)
        }
    }
}

extension Font {
    /// The site's small all-caps mono labels ("VISUAL LAB", "13.8 BILLION YEARS AGO").
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// A small ember mono label, wide-tracked and all caps.
struct Eyebrow: View {
    let text: String
    var tint: Color = Theme.ember

    init(_ text: String, tint: Color = Theme.ember) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text.uppercased())
            .font(.mono(9.5))
            .tracking(2.2)
            .foregroundStyle(tint)
    }
}

/// "CREATION OF COSMOS", thin and wide-tracked like the site's hero.
struct Wordmark: View {
    var size: CGFloat = 19

    var body: some View {
        Text("CREATION OF COSMOS")
            .font(.system(size: size, weight: .light))
            .tracking(size * 0.32)
            .foregroundStyle(.white.opacity(0.92))
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

/// The site's loader motif: a glowing orb travelling a faint ring, leaving a trail of light.
/// With a progress value the trail shows how far along it is; without one the orb circles gently.
struct OrbRing: View {
    var progress: Double?
    var size: CGFloat = 28
    var lineWidth: CGFloat = 1.2

    var body: some View {
        if let progress {
            ring(trailStart: 0, trailEnd: max(0.002, min(progress, 1)))
                .animation(Theme.ease, value: progress)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                // One lap every 2.6 s, easing in and out like the site's loader.
                let phase = t.truncatingRemainder(dividingBy: 2.6) / 2.6
                let head = 0.5 - cos(phase * .pi) / 2
                ring(trailStart: head - 0.28, trailEnd: head)
            }
        }
    }

    private func ring(trailStart: Double, trailEnd: Double) -> some View {
        let orb = min(max(3, size * 0.16), 7)
        return ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
            // The trail brightens toward the orb, drawn as short arcs so it renders the same everywhere.
            let length = trailEnd - trailStart
            ForEach(0..<16, id: \.self) { i in
                Circle()
                    .trim(from: length * Double(i) / 16, to: length * Double(i + 1) / 16)
                    .stroke(Theme.gold.opacity(0.9 * Double(i + 1) / 16), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            .rotationEffect(.degrees(-90 + 360 * trailStart))
            Circle()
                .fill(Color.white)
                .frame(width: orb, height: orb)
                .shadow(color: Theme.gold, radius: orb * 0.9)
                .shadow(color: Theme.gold.opacity(0.6), radius: orb * 2)
                .offset(y: -size / 2)
                .rotationEffect(.degrees(360 * trailEnd))
        }
        .frame(width: size, height: size)
    }
}

/// A hairline progress bar with a glowing orb at its head: the linear version of the orb motif.
struct OrbBar: View {
    var progress: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * max(0, min(progress, 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(height: 2)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.goldDeep.opacity(0.2), Theme.gold], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width, height: 2)
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
                    .shadow(color: Theme.gold, radius: 4)
                    .shadow(color: Theme.gold.opacity(0.6), radius: 9)
                    .offset(x: width - 2.5)
                    .opacity(progress > 0.002 ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .animation(Theme.ease, value: progress)
        }
        .frame(height: 8)
    }
}

struct SiteBadge: View {
    let site: String

    var body: some View {
        if !site.isEmpty {
            HStack(spacing: 4) {
                Circle().fill(Theme.siteColor(site)).frame(width: 5, height: 5)
                Text(site.uppercased()).font(.mono(9)).tracking(1.4).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = Theme.textDim

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .semibold)) }
            Text(text.uppercased()).font(.mono(9)).tracking(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.8))
    }
}

/// The site's cream pill ("Send inquiry →").
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .foregroundStyle(Color.black)
            .background(Capsule().fill(Theme.cream))
            .shadow(color: Theme.gold.opacity(enabled ? 0.25 : 0), radius: 10)
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.ease, value: configuration.isPressed)
    }
}

/// A quiet outlined pill for secondary actions.
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(.white.opacity(0.85))
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0.04)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
            .opacity(enabled ? 1 : 0.35)
            .animation(Theme.ease, value: configuration.isPressed)
    }
}

/// A field of stars that breathe very slowly. Positions come from a fixed seed so they never jump.
struct Starfield: View {
    var count = 160

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func next() -> Double {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return Double(seed >> 33) / Double(UInt64(1) << 31)
                }
                for _ in 0..<count {
                    let x = next() * size.width
                    let y = next() * size.height
                    let r = 0.4 + next() * 1.1
                    let base = 0.12 + next() * 0.5
                    let speed = 0.15 + next() * 0.35
                    let offset = next() * 6.28
                    let alpha = base * (0.65 + 0.35 * sin(t * speed + offset))
                    let warm = next() > 0.8
                    canvas.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                                with: .color(warm ? Theme.gold.opacity(alpha) : .white.opacity(alpha)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Warm light rising from below the horizon, like the black hole's disk on the site.
struct HorizonGlow: View {
    var body: some View {
        GeometryReader { geo in
            Ellipse()
                .fill(RadialGradient(colors: [Theme.gold.opacity(0.22), Theme.goldDeep.opacity(0.08), .clear],
                                     center: .center, startRadius: 0, endRadius: geo.size.width * 0.5))
                .frame(width: geo.size.width * 1.2, height: geo.size.height * 0.9)
                .position(x: geo.size.width / 2, y: geo.size.height * 1.05)
                .blur(radius: 30)
        }
        .allowsHitTesting(false)
    }
}
