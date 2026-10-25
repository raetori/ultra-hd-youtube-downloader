import SwiftUI

struct ItemRow: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject private var queue: QueueManager
    @EnvironmentObject private var settings: AppSettings
    @State private var showTrim = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    SiteBadge(site: item.site)
                    Text(item.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .tracking(-0.1)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(item.url)
                }
                nameField
                optionRow
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card.opacity(hovering ? 1.6 : 1))
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(borderColor, lineWidth: 0.8))
        .shadow(color: item.state.isActive ? Theme.gold.opacity(0.12) : .clear, radius: 18)
        .animation(Theme.ease, value: item.state)
        .animation(Theme.ease, value: hovering)
        .onHover { hovering = $0 }
        .onAppear {
            // Guide screenshot of the trim box (CI only).
            if Shot.is("trim") && item.isTrimmed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showTrim = true }
            }
        }
        .contextMenu {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            if let file = item.outputURL { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
            Divider()
            Button("Remove", role: .destructive) { queue.remove(item) }
        }
    }

    private var borderColor: Color {
        switch item.state {
        case .failed: return Theme.danger.opacity(0.35)
        case .done: return Theme.gold.opacity(0.22)
        case .downloading, .converting: return Theme.gold.opacity(0.4)
        default: return Theme.hairline
        }
    }

    // MARK: Pieces

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = item.thumbnail {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                        else { placeholder }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 136, height: 77)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.8))

            if let duration = item.duration {
                Text(TimeFormat.string(duration))
                    .font(.mono(9.5))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .foregroundStyle(.white)
                    .padding(5)
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Theme.space
            if item.state == .fetching { OrbRing(progress: nil, size: 26) }
            else { Image(systemName: item.quality.symbol).foregroundStyle(Theme.gold.opacity(0.5)) }
        }
    }

    private var nameField: some View {
        HStack(spacing: 4) {
            Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("File name", text: $item.fileName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .disabled(!item.state.canEdit)
            Text("." + item.quality.fileExtension).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(item.state.canEdit ? 0.05 : 0.02)))
        .help("Rename the file before downloading")
    }

    private var optionRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Quality.allCases) { quality in
                    Button { setQuality(quality) } label: {
                        if quality == item.quality { Label(quality.label, systemImage: "checkmark") } else { Text(quality.label) }
                    }
                }
            } label: {
                Label(item.quality.shortLabel, systemImage: item.quality.symbol).font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!item.state.canEdit)

            Button { showTrim = true } label: {
                Label(item.trimLabel ?? "Trim", systemImage: "scissors").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(item.isTrimmed ? Theme.gold : Theme.textDim)
            .disabled(!item.state.canEdit)
            .popover(isPresented: $showTrim, arrowEdge: .bottom) { TrimEditor(item: item) }

            if let resolution = item.resolution, !item.quality.isAudio {
                Chip(text: item.quality == .hd1080 && ["4K", "8K", "1440p"].contains(resolution) ? "1080p" : resolution, tint: Theme.accent)
            }
            if let badge = item.quality.outputBadge { Chip(text: badge, symbol: "checkmark.seal", tint: Theme.textDim) }
            if item.useLogin { Chip(text: "Using \(settings.loginBrowserName) login", symbol: "person.crop.circle", tint: Theme.ember) }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .downloading, .converting:
            VStack(alignment: .leading, spacing: 4) {
                OrbBar(progress: item.progress)
                Text(item.detail.uppercased()).font(.mono(9.5)).tracking(0.8).foregroundStyle(Theme.gold.opacity(0.85))
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Text(item.errorMessage ?? "Something went wrong.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if item.needsLogin && !item.useLogin {
                    HStack(spacing: 6) {
                        Text("This site wants you to be logged in.").font(.system(size: 11)).foregroundStyle(.secondary)
                        if settings.loginBrowser == "none" {
                            OpenSettingsButton(label: "Choose a browser login…")
                        } else {
                            Button("Use my \(settings.loginBrowserName) login") { queue.retry(item, withLogin: true) }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                        }
                    }
                }
            }
        case .done:
            Label(item.detail, systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.gold)
        default:
            Text(item.detail).font(.system(size: 11)).foregroundStyle(Theme.textDim)
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            switch item.state {
            case .ready, .cancelled:
                iconButton("arrow.down", help: "Download", tint: Theme.gold) { queue.start(item) }
            case .failed:
                iconButton("arrow.clockwise", help: "Try again", tint: Theme.gold) { queue.retry(item) }
            case .downloading, .converting:
                Button { queue.cancel(item) } label: {
                    ZStack {
                        OrbRing(progress: item.progress, size: 26)
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(hovering ? 0.9 : 0))
                    }
                }
                .buttonStyle(.borderless)
                .help("Cancel")
            case .queued:
                iconButton("xmark", help: "Cancel", tint: Theme.textDim) { queue.cancel(item) }
            case .done:
                iconButton("magnifyingglass", help: "Show in Finder", tint: Theme.gold) {
                    if let file = item.outputURL { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            case .fetching:
                OrbRing(progress: nil, size: 22).frame(width: 28, height: 28)
            }
            if !item.state.isActive && item.state != .queued {
                iconButton("trash", help: "Remove from list", tint: Theme.textDim, size: 11, ring: false) { queue.remove(item) }
                    .opacity(hovering ? 1 : 0.35)
            }
        }
        .frame(width: 32)
    }

    private func iconButton(_ symbol: String, help: String, tint: Color, size: CGFloat = 11, ring: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().strokeBorder(tint.opacity(ring ? 0.4 : 0), lineWidth: 0.8))
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func setQuality(_ quality: Quality) {
        guard quality != item.quality else { return }
        item.quality = quality
        // Formats depend on the quality, so look the link up again for accurate size and resolution.
        if item.infoLoaded { queue.fetchInfo(item) }
    }
}

/// Opens the app's Settings window from inside a view (works on macOS 13 and later).
struct OpenSettingsButton: View {
    let label: String
    var ghost = false

    var body: some View {
        // macOS 14 and later ignore the old menu action, so use SwiftUI's own link there.
        if #available(macOS 14, *) {
            SettingsLink { Text(label) }
                .modifier(SettingsButtonLook(ghost: ghost))
        } else {
            Button(label) {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            .modifier(SettingsButtonLook(ghost: ghost))
        }
    }
}

private struct SettingsButtonLook: ViewModifier {
    let ghost: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if ghost {
            content.buttonStyle(GhostButtonStyle())
        } else {
            content.buttonStyle(.link).font(.system(size: 11))
        }
    }
}

struct TrimEditor: View {
    @ObservedObject var item: DownloadItem
    @Environment(\.dismiss) private var dismiss
    @State private var startText = ""
    @State private var endText = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Trim")
            Text("Keep only part of the video. Use minutes:seconds, like 1:30.\nLeave End empty to keep everything after Start.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                field("Start", text: $startText, placeholder: "0:00")
                field("End", text: $endText, placeholder: item.duration.map(TimeFormat.string) ?? "end")
            }
            if let duration = item.duration {
                Text("Full length: \(TimeFormat.string(duration))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger)
            }
            HStack {
                Button("Remove trim") {
                    item.trimStart = nil
                    item.trimEnd = nil
                    dismiss()
                }
                .disabled(!item.isTrimmed)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            startText = item.trimStart.map(TimeFormat.string) ?? ""
            endText = item.trimEnd.map(TimeFormat.string) ?? ""
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13).monospacedDigit())
        }
    }

    private func apply() {
        let startEmpty = startText.trimmingCharacters(in: .whitespaces).isEmpty
        let endEmpty = endText.trimmingCharacters(in: .whitespaces).isEmpty
        let start = startEmpty ? nil : TimeFormat.parse(startText)
        let end = endEmpty ? nil : TimeFormat.parse(endText)
        if (!startEmpty && start == nil) || (!endEmpty && end == nil) {
            error = "Use a time like 1:30 or 1:02:30."
            return
        }
        if let s = start, let e = end, e <= s {
            error = "End must be after Start."
            return
        }
        if let duration = item.duration, let s = start, s >= duration {
            error = "Start is past the end of the video."
            return
        }
        item.trimStart = (start ?? 0) > 0 ? start : nil
        item.trimEnd = end
        if let duration = item.duration, let e = end, e >= duration { item.trimEnd = nil }
        dismiss()
    }
}
