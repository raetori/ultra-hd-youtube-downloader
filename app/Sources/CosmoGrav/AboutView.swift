import SwiftUI

/// The About window, in the same deep-space style as the app and creationofcosmos.com.
struct AboutView: View {
    var body: some View {
        ZStack {
            Theme.space
            Starfield(count: 110)
            HorizonGlow()
            VStack(spacing: 0) {
                CosmosMark()
                    .fill(.white)
                    .frame(width: 48, height: 48)
                    .shadow(color: Theme.gold.opacity(0.45), radius: 14)
                    .padding(.bottom, 20)
                Eyebrow("Visual Lab")
                    .padding(.bottom, 8)
                Wordmark(size: 15)
                    .padding(.bottom, 6)
                Text("VIDEO EDITING STUDIO · MAKATI, PHILIPPINES")
                    .font(.mono(9))
                    .tracking(1.6)
                    .foregroundStyle(Theme.textDim)

                GoldRule().padding(.vertical, 24)

                Eyebrow("The Founder")
                    .padding(.bottom, 8)
                Text("Raeden Toribio")
                    .font(.system(size: 20, weight: .medium))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                    .padding(.bottom, 5)
                Text("FOUNDER · 21 YEARS IN THE EDIT SUITE")
                    .font(.mono(9.5))
                    .tracking(1.6)
                    .foregroundStyle(Theme.gold.opacity(0.85))
                    .padding(.bottom, 16)
                Text("We believe every creative deserves a way up. We're building a worldwide community where editors and creatives share what they know, lift each other up, and turn their craft into a living.")
                    .padding(.bottom, 10)
                Text("From a first timeline to the biggest screens on Earth, we want to help every editor reach the place they've always dreamed of, without spending years learning it alone.")

                GoldRule().padding(.vertical, 24)

                Text("COSMOGRAV · VERSION \(Updater.currentVersion)")
                    .font(.mono(9.5))
                    .tracking(1.6)
                    .foregroundStyle(Theme.gold.opacity(0.8))
                    .padding(.bottom, 8)
                Text("Footage from the source to the edit suite, ready for Premiere Pro.")
                    .padding(.bottom, 18)
                Link(destination: Tools.website) {
                    Text("Visit creationofcosmos.com  →")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.bottom, 20)
                Text("Built on yt-dlp, FFmpeg and Deno.\nPlease only download content you have the rights to use.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .lineSpacing(2)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.75))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 44)
            .padding(.vertical, 28)
        }
        .frame(width: 500, height: 670)
        .preferredColorScheme(.dark)
    }
}

/// A hairline of warm light that fades out at both ends.
struct GoldRule: View {
    var body: some View {
        LinearGradient(colors: [.clear, Theme.gold.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: 220, height: 1)
    }
}

/// Opens the About window from a menu or a button.
struct AboutButton: View {
    var title = "About"
    var ghost = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if ghost {
            Button(title) { open() }.buttonStyle(GhostButtonStyle())
        } else {
            Button(title) { open() }
        }
    }

    private func open() {
        openWindow(id: "about")
        NSApp.activate(ignoringOtherApps: true)
    }
}
