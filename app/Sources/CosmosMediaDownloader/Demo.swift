import Foundation

extension QueueManager {
    /// Sample rows in every state, so the design can be checked without touching the network.
    func loadDemo() {
        func make(_ title: String, site: String, duration: Double, resolution: String, quality: Quality,
                  state: ItemState, progress: Double = 0, detail: String) -> DownloadItem {
            let item = DownloadItem(url: "https://example.com/\(title.hashValue)", quality: quality, title: title)
            item.site = site
            item.duration = duration
            item.resolution = resolution
            item.state = state
            item.progress = progress
            item.detail = detail
            item.infoLoaded = true
            return item
        }
        let trimmed = make("Interstellar docking scene reference", site: "YouTube", duration: 241, resolution: "4K",
                           quality: .best, state: .ready, detail: "Ready · about 820 MB")
        trimmed.trimStart = 61
        trimmed.trimEnd = 94
        items = [
            make("Creation of Cosmos launch film", site: "YouTube", duration: 152, resolution: "4K", quality: .best,
                 state: .downloading, progress: 0.62, detail: "62% · 14.2 MB/s · 0:09 left"),
            make("Behind the cut: Makati studio session", site: "Instagram", duration: 48, resolution: "1080p", quality: .hd1080,
                 state: .converting, progress: 0.35, detail: "Making it Premiere-ready · 35%"),
            trimmed,
            make("Night drive b-roll", site: "TikTok", duration: 27, resolution: "1080p", quality: .prores,
                 state: .done, progress: 1, detail: "Saved to Downloads"),
            make("Client brief voice memo", site: "Facebook", duration: 95, resolution: "720p", quality: .wav,
                 state: .queued, detail: "Waiting for a free slot"),
        ]
    }
}
