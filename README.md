# CosmoGrav

_For Mac and Windows. Formerly Cosmos Media Downloader._

<img src="assets/icon.png" width="96" align="right">

Download videos from YouTube, TikTok, Instagram, Facebook, Vimeo and more in HD, as **H.264 MP4 files that import straight into Premiere Pro**. On Mac it also downloads any other file (zip, pdf, images, audio, project files) and public Google Drive, Dropbox and OneDrive links, faster and resumable. Made by [Creation of Cosmos](https://www.creationofcosmos.com).

**Please only download content you have the rights to use.**

## Install on Windows (once, about 2 minutes)

1. Click **Start**, type `PowerShell`, and press **Enter**. A blue window opens.
2. Copy this line. Click inside the blue window, **right-click** to paste it, and press **Enter**:

```powershell
irm https://raw.githubusercontent.com/raetori/ultra-hd-youtube-downloader/main/install.ps1 | iex
```

3. Wait until it says **All set!**. CosmoGrav opens by itself. You can close the blue window.

CosmoGrav is now in your **Start menu** and on your **desktop**. No admin password and no "Windows protected your PC" warning. Needs Windows 10 or 11 (64-bit).

## Install on Mac (once, about 2 minutes)

1. Open **Terminal**: press **Cmd + Space**, type `Terminal`, press **Return**.
2. Copy this line, paste it into Terminal (**Cmd + V**), and press **Return**:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/raetori/ultra-hd-youtube-downloader/main/install.sh)"
```

3. Wait until it says **All set!**. CosmoGrav opens by itself. You can close Terminal.

CosmoGrav is now in your **Applications** folder. No Homebrew, no admin password and no security warnings. Needs macOS 13 (Ventura) or newer.

## Updates

When a new version is out, CosmoGrav shows an **Update now** button at the top. Click it and the app updates and reopens. Nothing else to do.

## Use it

1. Copy one or more links, then click **Paste links** (or drag links into the window). Playlists are added as separate videos.
2. For each video you can:
   - **Rename** the file (click the name)
   - **Trim** to a start and end time, like `1:30`
   - Pick the **quality**: Best HD (up to 4K), HD 1080p (faster), ProRes 422 HQ (.mov, for heavy editing and grading), Audio MP3, Audio WAV, or **Captions only (SRT)** (Mac), which saves just the subtitles and no video
3. Click **Download**. Two videos download at a time by default (choose 1, 2 or 3 with **At once**). Cancel any video with its ✕ button.
4. Pick where files go with **Save to**. Click the folder button on a finished video to see it in File Explorer (Windows) or Finder (Mac).
5. Copied a link in your browser? Switch to the app and it offers to add it.
6. Got a long list (dozens or hundreds of links)? Click **Import list** (⌘O) on Mac, then open a `.txt` or `.csv` file or paste the list. You can also drop the file on the window, and a paste of more than 20 links opens the same screen. CosmoGrav removes repeats, lists any lines it skipped, keeps videos, Shorts and playlists apart, and divides the list into batches of 10, 25, 50 or 100. Pick **Download as** to set the quality for the whole list, including Captions only (SRT). Each batch can go into its own folder, and batches can download one after another on their own. **Save batches as files** writes each batch to its own `.txt`. The list is read only on your computer and only web links (http/https) are accepted.
7. Coming from **JDownloader**? CosmoGrav reads `.crawljob` files (Mac), in both the plain `text=` form and the JSON form. Double-click one, drop it on the window, or use **File → Open .crawljob** (⇧⌘O). You see each package with its links and folder, tick the ones you want, and add them. CosmoGrav uses `text` (the links), `packageName` (a folder of that name in your save folder), `downloadFolder` (including `<jd:packagename>`; it must be inside your home folder or on an external drive), `filename`, `enabled` and `autoStart`. Other fields, such as priority, chunks and passwords, are ignored and never stored.
   - **Folder Watch**: turn it on in **Settings** and pick a folder (by default `Downloads/CosmoGrav Folder Watch`). Any `.crawljob` file saved there is added on its own within a few seconds, and then moved into an `added` folder inside it, just like JDownloader's Folder Watch.
8. **Files and cloud links** (Mac): paste a link to any file, like a `.zip`, `.pdf`, `.wav`, `.psd` or a project file, or a public share link from **Google Drive**, **Dropbox** or **OneDrive**. The file is kept exactly as it is (only video gets converted). Big files download over up to 8 connections at once, a dropped connection retries on its own, and the ✕ button pauses: click Download again (even after quitting) and it carries on where it stopped. Share links must be set to "Anyone with the link". Google Drive folders and MEGA links can't be downloaded from a link (MEGA encrypts its files), and nothing that needs a login, a captcha or a wait in the browser is bypassed.
9. In **Settings** you can also save captions (.srt) next to each video and get a notification when downloads finish.

Every video comes out as H.264 + AAC MP4. If the site's file is already H.264 it is kept as is (instant). Otherwise it is converted with your computer's built-in video encoder (Apple's on Mac; NVIDIA, Intel or AMD graphics on Windows, or the processor when there is none).

### Instagram, Facebook and logins

Public posts usually work without logging in. If a site refuses, the video shows **Use my login**: pick your browser once in **Settings** and the app borrows that browser's login. It is never used unless you click it. On Windows, **Firefox** works best: Chrome and Edge lock their logins away from other apps.

## Privacy

Everything runs on your own computer. No accounts, no tracking, nothing is sent to Creation of Cosmos or GitHub. History is stored only on your computer and can be cleared in Settings.

## Troubleshooting

- **A download fails**: check the link and click the retry button. In Settings, **Update now** refreshes the download engine (it also updates itself daily).
- **Still failing**: run the install line again. It repairs everything.
- **Windows: "irm is not recognized"**: you opened the old Command Prompt (black window). Open **PowerShell** instead (step 1).

## Uninstall

- **Windows**: Settings → Apps → Installed apps → **CosmoGrav** → Uninstall. Your downloaded videos are kept.
- **Mac**: drag **CosmoGrav** from Applications to the Trash, then delete `~/Library/Application Support/TeamYTDownloader` (in Finder: Cmd + Shift + G, paste the path).

## For maintainers

- `app/` is the Mac app (SwiftUI). Pushing changes to `app/` on `main` makes GitHub build it and publish a release `v…` (`.github/workflows/build-app.yml`).
- `windows/` is the Windows app (WPF, .NET Framework 4.8, which every Windows 10 and 11 PC has). Pushing changes to `windows/` or `install.ps1` builds it on Windows, installs it with `install.ps1`, runs real downloads, photographs every screen, and on `main` publishes a release `win-v…` (`.github/workflows/build-windows.yml`). Windows releases are never marked "latest", so they don't affect the Mac installer.
- To ship an update to everyone, raise the number in `app/VERSION` (Mac) or `windows/VERSION` (Windows). Apps on a lower version offer **Update now**.
- `install.sh` (Mac) and `install.ps1` (Windows) install the download tools and the latest release.
- Screenshots of every Windows screen from the last build are on the [ci-preview](https://github.com/raetori/ultra-hd-youtube-downloader/releases/tag/ci-preview) pre-release (`windows-*.png`).

---

Built on [yt-dlp](https://github.com/yt-dlp/yt-dlp), [FFmpeg](https://ffmpeg.org) and [Deno](https://deno.com).
