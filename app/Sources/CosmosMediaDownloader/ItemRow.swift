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
                        .font(.system(size: 13, weight: .semibold))
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
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(borderColor, lineWidth: 1))
        .onHover { hovering = $0 }
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
        case .failed: return .red.opacity(0.35)
        case .done: return .green.opacity(0.3)
        case .downloading, .converting: return Theme.accent.opacity(0.4)
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
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let duration = item.duration {
                Text(TimeFormat.string(duration))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.7)))
                    .foregroundStyle(.white)
                    .padding(5)
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Theme.space
            if item.state == .fetching { ProgressView().controlSize(.small).tint(.white) }
            else { Image(systemName: item.quality.symbol).foregroundStyle(.white.opacity(0.4)) }
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
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(item.state.canEdit ? 0.05 : 0.02)))
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
            .foregroundStyle(item.isTrimmed ? Theme.accent : .secondary)
            .disabled(!item.state.canEdit)
            .popover(isPresented: $showTrim, arrowEdge: .bottom) { TrimEditor(item: item) }

            if let resolution = item.resolution, !item.quality.isAudio {
                Chip(text: item.quality == .hd1080 && ["4K", "8K", "1440p"].contains(resolution) ? "1080p" : resolution, tint: Theme.accent)
            }
            if !item.quality.isAudio { Chip(text: "H.264 MP4", symbol: "checkmark.seal.fill", tint: .green) }
            if item.useLogin { Chip(text: "Using \(settings.loginBrowserName) login", symbol: "person.crop.circle", tint: .orange) }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .downloading, .converting:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: item.progress).tint(item.state == .converting ? .green : Theme.accent)
                Text(item.detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Text(item.errorMessage ?? "Something went wrong.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
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
            Label(item.detail, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        default:
            Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            switch item.state {
            case .ready, .cancelled:
                iconButton("arrow.down.circle.fill", help: "Download", tint: Theme.accent) { queue.start(item) }
            case .failed:
                iconButton("arrow.clockwise.circle.fill", help: "Try again", tint: Theme.accent) { queue.retry(item) }
            case .queued, .downloading, .converting:
                iconButton("xmark.circle.fill", help: "Cancel", tint: .secondary) { queue.cancel(item) }
            case .done:
                iconButton("magnifyingglass.circle.fill", help: "Show in Finder", tint: Theme.accent) {
                    if let file = item.outputURL { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            case .fetching:
                ProgressView().controlSize(.small).frame(width: 24, height: 24)
            }
            if !item.state.isActive && item.state != .queued {
                iconButton("trash", help: "Remove from list", tint: .secondary, size: 13) { queue.remove(item) }
                    .opacity(hovering ? 1 : 0.35)
            }
        }
        .frame(width: 30)
    }

    private func iconButton(_ symbol: String, help: String, tint: Color, size: CGFloat = 22, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(tint)
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

    var body: some View {
        Button(label) {
            if #available(macOS 14, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
        .buttonStyle(.link)
        .font(.system(size: 11))
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
            Text("Trim").font(.headline)
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
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
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
