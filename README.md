# CosmoGrav

_For Mac and Windows. Formerly Cosmos Media Downloader._

<img src="assets/icon.png" width="96" align="right">

Download videos from YouTube, TikTok, Instagram, Facebook, Vimeo and more in HD, as **H.264 MP4 files that import straight into Premiere Pro**. Made by [Creation of Cosmos](https://www.creationofcosmos.com).

**Please only download content you have the rights to use.**

## Install on Windows (once, about 2 minutes)

### Option A: download and double-click

1. Download **[CosmoGrav-Setup.exe](https://github.com/raetori/ultra-hd-youtube-downloader/releases/download/windows/CosmoGrav-Setup.exe)** and open it.
2. Windows shows a blue box, **"Windows protected your PC"**. This appears for apps from small studios that haven't paid Microsoft for a signing certificate yet. Click **More info**, then **Run anyway**. (If Edge says the file "isn't commonly downloaded", click **…** next to it, then **Keep**, then **Keep anyway**.)
3. Click **Install CosmoGrav →**. When it says **All set!**, CosmoGrav opens by itself. You can delete the setup file.

### Option B: one line in PowerShell (no warnings at all)

1. Click **Start**, type `PowerShell`, and press **Enter**. A blue window opens.
2. Copy this line. Click inside the blue window, **right-click** to paste it, and press **Enter**:

```powershell
irm https://raw.githubusercontent.com/raetori/ultra-hd-youtube-downloader/main/install.ps1 | iex
```

3. Wait until it says **All set!**. CosmoGrav opens by itself. You can close the blue window.

Either way, CosmoGrav is now in your **Start menu** and on your **desktop**. No admin password needed. Needs Windows 10 or 11 (64-bit).

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
   - Pick the **quality**: Best HD (up to 4K), HD 1080p (faster), ProRes 422 HQ (.mov, for heavy editing and grading), Audio MP3 or Audio WAV
3. Click **Download**. Two videos download at a time by default (choose 1, 2 or 3 with **At once**). Cancel any video with its ✕ button.
4. Pick where files go with **Save to**. Click the folder button on a finished video to see it in File Explorer (Windows) or Finder (Mac).
5. Copied a link in your browser? Switch to the app and it offers to add it.
6. In **Settings** you can also save captions (.srt) next to each video and get a notification when downloads finish.

Every video comes out as H.264 + AAC MP4. If the site's file is already H.264 it is kept as is (instant). Otherwise it is converted with your computer's built-in video encoder (Apple's on Mac; NVIDIA, Intel or AMD graphics on Windows, or the processor when there is none).

### Instagram, Facebook and logins

Public posts usually work without logging in. If a site refuses, the video shows **Use my login**: pick your browser once in **Settings** and the app borrows that browser's login. It is never used unless you click it. On Windows, **Firefox** works best: Chrome and Edge lock their logins away from other apps.

## Privacy

Everything runs on your own computer. No accounts, no tracking, nothing is sent to Creation of Cosmos or GitHub. History is stored only on your computer and can be cleared in Settings.

## Troubleshooting

- **A download fails**: check the link and click the retry button. In Settings, **Update now** refreshes the download engine (it also updates itself daily).
- **Still failing**: run the installer again (either option). It repairs everything.
- **Windows: "irm is not recognized"**: you opened the old Command Prompt (black window). Open **PowerShell** instead (step 1).

## Uninstall

- **Windows**: Settings → Apps → Installed apps → **CosmoGrav** → Uninstall. Your downloaded videos are kept.
- **Mac**: drag **CosmoGrav** from Applications to the Trash, then delete `~/Library/Application Support/TeamYTDownloader` (in Finder: Cmd + Shift + G, paste the path).

## For maintainers

- `app/` is the Mac app (SwiftUI). Pushing changes to `app/` on `main` makes GitHub build it and publish a release `v…` (`.github/workflows/build-app.yml`).
- `windows/` is the Windows app (WPF, .NET Framework 4.8, which every Windows 10 and 11 PC has). Pushing changes to `windows/` or `install.ps1` builds it on Windows, installs it with `install.ps1`, runs real downloads, photographs every screen, and on `main` publishes a release `win-v…` (`.github/workflows/build-windows.yml`). It also refreshes `CosmoGrav-Setup.exe` on the `windows` release, so the download link above never changes. Windows releases are never marked "latest", so they don't affect the Mac installer.
- `CosmoGrav-Setup.exe` is the app itself: opened from anywhere but its installed folder, it installs itself by running the built-in copy of `install.ps1`.
- To ship an update to everyone, raise the number in `app/VERSION` (Mac) or `windows/VERSION` (Windows). Apps on a lower version offer **Update now**.
- `install.sh` (Mac) and `install.ps1` (Windows) install the download tools and the latest release.
- Screenshots of every Windows screen from the last build are on the [ci-preview](https://github.com/raetori/ultra-hd-youtube-downloader/releases/tag/ci-preview) pre-release (`windows-*.png`).

---

Built on [yt-dlp](https://github.com/yt-dlp/yt-dlp), [FFmpeg](https://ffmpeg.org) and [Deno](https://deno.com).
