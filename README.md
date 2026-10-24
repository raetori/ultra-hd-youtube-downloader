# Cosmos Media Downloader (Mac)

<img src="assets/icon.png" width="96" align="right">

Download videos from YouTube, TikTok, Instagram, Facebook, Vimeo and more in HD, as **H.264 MP4 files that import straight into Premiere Pro**. Made by [Creation of Cosmos](https://www.creationofcosmos.com).

**Please only download content you have the rights to use.**

## Install (once, about 2 minutes)

1. Open **Terminal**: press Cmd + Space, type `Terminal`, press Return.
2. Paste this line. It starts on its own:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/raetori/ultra-hd-youtube-downloader/main/install.sh)"
```

3. When it says **All set!**, the app opens. Close Terminal.

No Homebrew, no admin password, no security warnings. Needs macOS 13 (Ventura) or newer. When a new version is out, the app shows an **Update now** button.

## Use it

1. Copy one or more links, then click **Paste** (or drag links into the window). Playlists are added as separate videos.
2. For each video you can:
   - **Rename** the file (click the name)
   - **Trim** to a start and end time
   - Pick the **quality**: Best HD (up to 4K), HD 1080p (faster), Audio MP3 or Audio WAV
3. Click **Download all**. Two videos download at a time by default (choose 1–3 with **At once**). Cancel any video with its ✕ button.
4. Pick where files go with **Save to**. Click the magnifier on a finished video to see it in Finder.

Every video comes out as H.264 + AAC MP4. If the site's file is already H.264 it is kept as is (instant); otherwise it is converted using the Mac's built-in video encoder.

### Instagram, Facebook and logins

Public posts usually work without logging in. If a site refuses, the video shows **Use my login**: pick your browser once in **Settings** (Cmd + ,) and the app borrows that browser's login. It is never used unless you click it.

## Privacy

Everything runs on your Mac. No accounts, no tracking, nothing is sent to Creation of Cosmos or GitHub. History is stored only on your Mac and can be cleared in Settings.

## Troubleshooting

- **A download fails**: check the link and click the retry button. In Settings, **Update now** refreshes the download engine (it also updates itself daily).
- **Still failing**: run the install line again. It repairs everything.

## Uninstall

Drag **Cosmos Media Downloader** from Applications to the Trash, then delete `~/Library/Application Support/TeamYTDownloader` (in Finder: Cmd + Shift + G, paste the path).

## For maintainers

- `app/` is the SwiftUI app. Pushing changes to `app/` makes GitHub build it and publish a release (`.github/workflows/build-app.yml`).
- To ship an update to everyone, raise the number in `app/VERSION`. Apps on that version or lower offer **Update now**.
- `install.sh` installs the download tools and the latest release.

---

Built on [yt-dlp](https://github.com/yt-dlp/yt-dlp), [FFmpeg](https://ffmpeg.org) and [Deno](https://deno.com).
