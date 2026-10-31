import AppKit
import SwiftUI

/// Shows what's in one or more JDownloader .crawljob files, package by package, before anything is downloaded.
struct CrawljobView: View {
    @EnvironmentObject private var queue: QueueManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    let draft: CrawljobDraft
    @State private var jobs: [CrawlJob]
    @State private var quality: Quality
    @State private var startNow = true

    init(draft: CrawljobDraft) {
        self.draft = draft
        _jobs = State(initialValue: draft.report.jobs)
        _quality = State(initialValue: UserDefaults.standard.string(forKey: "defaultQuality").flatMap(Quality.init(rawValue:)) ?? .best)
    }

    private var chosen: [CrawlJob] { jobs.filter(\.include) }
    private var chosenLinks: Int { chosen.reduce(0) { $0 + $1.links.count } }
    private var report: CrawljobReport { draft.report }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = report.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Theme.ember)
                    }
                    if !jobs.isEmpty {
                        summary
                        packageList
                        options
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            footer
        }
        .frame(width: 660, height: 600)
        .background(Theme.ink)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow("Crawljob · \(draft.name)")
                Text("Link jobs from JDownloader, ready to download.").font(.system(size: 20, weight: .medium)).tracking(-0.3)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .background(ZStack { Theme.space; Starfield() })
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("What's in it", tint: Theme.textDim)
            HStack(spacing: 6) {
                Chip(text: jobs.count == 1 ? "1 package" : "\(jobs.count) packages", tint: Theme.gold)
                Chip(text: report.linkCount == 1 ? "1 link" : "\(report.linkCount) links")
                if report.disabled > 0 { Chip(text: "\(report.disabled) turned off", symbol: "minus.circle") }
                if report.empty > 0 { Chip(text: "\(report.empty) without links", symbol: "minus.circle") }
            }
            let skipped = jobs.reduce(0) { $0 + $1.skippedLinks }
            if skipped > 0 {
                Text("\(skipped) line\(skipped == 1 ? " wasn't a web link" : "s weren't web links") and \(skipped == 1 ? "was" : "were") left out.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
            }
            if !report.ignoredFields.isEmpty {
                Text("Not used by CosmoGrav: " + report.ignoredFields.sorted().joined(separator: ", ") + ".")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
            }
        }
    }

    private var packageList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Eyebrow("Packages", tint: Theme.textDim)
                Spacer()
                if jobs.count > 1 {
                    Button(chosen.count == jobs.count ? "Untick all" : "Tick all") {
                        let on = chosen.count != jobs.count
                        for index in jobs.indices { jobs[index].include = on }
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.gold)
                }
            }
            ForEach($jobs) { $job in
                HStack(alignment: .top, spacing: 10) {
                    Toggle("", isOn: $job.include).toggleStyle(.checkbox).labelsHidden()
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(job.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Text(job.links.count == 1 ? "1 link" : "\(job.links.count) links")
                                .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                            if let auto = job.autoStart {
                                Chip(text: auto ? "starts on its own" : "waits for you", tint: auto ? Theme.gold : Theme.textDim)
                            }
                        }
                        Label(destinationText(job), systemImage: "folder")
                            .font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                        if job.links.count == 1, let name = Crawljob.fileName(job.filename) {
                            Label("Saved as \(name)", systemImage: "character.cursor.ibeam")
                                .font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
                .opacity(job.include ? 1 : 0.5)
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Options", tint: Theme.textDim)
            HStack(spacing: 10) {
                Text("Download as").font(.system(size: 12))
                Picker("", selection: $quality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            Toggle("Start downloading right away", isOn: $startNow).toggleStyle(.checkbox).font(.system(size: 12))
                .help("Packages whose file says autoStart=TRUE or FALSE follow the file instead")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Links are read only on this Mac. Only web links (http/https) are used.")
                .font(.system(size: 11)).foregroundStyle(Theme.textDim)
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction)
            Button {
                queue.addCrawljobs(chosen, quality: quality, startByDefault: startNow)
                dismiss()
            } label: {
                Text(chosenLinks == 0 ? "Add to queue  →" : "Add \(chosenLinks) link\(chosenLinks == 1 ? "" : "s")  →")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(chosenLinks == 0)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.6))
    }

    private func destinationText(_ job: CrawlJob) -> String {
        let place = Crawljob.destination(for: job, saveFolder: settings.saveFolder)
        let url = place.folder.reduce(place.base) { $0.appendingPathComponent($1, isDirectory: true) }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}
