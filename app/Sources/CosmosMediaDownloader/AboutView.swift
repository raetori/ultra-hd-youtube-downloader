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
                    .frame(width: 52, height: 52)
                    .shadow(color: Theme.gold.opacity(0.45), radius: 14)
                    .padding(.bottom, 22)
                Eyebrow("Visual Lab")
                    .padding(.bottom, 8)
                Wordmark(size: 15)
                    .padding(.bottom, 6)
                Text("MEDIA DOWNLOADER · VERSION \(Updater.currentVersion)")
                    .font(.mono(9.5))
                    .tracking(1.6)
                    .foregroundStyle(Theme.gold.opacity(0.8))
                    .padding(.bottom, 22)
                Text("We're a video editing studio in Makati, Philippines.\nThis app brings footage from the source to the edit suite,\nready for Premiere Pro.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.bottom, 22)
                Link(destination: Tools.website) {
                    Text("Visit creationofcosmos.com  →")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.bottom, 26)
                Text("Built on yt-dlp, FFmpeg and Deno.\nPlease only download content you have the rights to use.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(36)
        }
        .frame(width: 440, height: 470)
        .preferredColorScheme(.dark)
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
