# CosmoGrav handoff (read this first)

This is the briefing for any new Claude conversation, any new Claude Code session, or any person picking up work on CosmoGrav and the other Creation of Cosmos apps. The **Live status** section at the bottom refreshes itself on GitHub after every change. The rest is kept current by whoever (Claude or Raeden) finishes a piece of work, following the rules in "Keeping this file current".

Live copy, always the newest: https://raw.githubusercontent.com/raetori/ultra-hd-youtube-downloader/main/HANDOFF.md

## Start a new Claude chat with this

Paste this as the first message of any new conversation:

```
Read https://raw.githubusercontent.com/raetori/ultra-hd-youtube-downloader/main/HANDOFF.md before anything else and treat it as your project briefing and my standing rules. Then: <what I want today>
```

Claude Code sessions on this repository read it on their own (see `CLAUDE.md`).

## Who you are working with

- **Raeden Toribio**, founder of Creation of Cosmos (https://www.creationofcosmos.com), video editor for 21 years. Builds tools for their editing team. GitHub: `raetori`.
- Wants work **finished and live end to end**: build it, test it, merge it, release it. Don't hand back steps like "now click Merge". Only stop to ask when a permission or protection truly blocks you, or the step can't be undone.
- Replies: plain, direct, short. No filler, no long summaries.
- **Privacy is top priority.** Never put Raeden's email, passwords, tokens, API keys or other credentials in code, commits, issues, PRs, docs, logs or this file. Commits use GitHub's private noreply address. If a site or tool asks for contact details, use a generic name or ask first.
- Security on every build: least permissions, nothing secret committed (`.gitignore` blocks `.env`, keys, `.vercel`), downloads only over HTTPS, no telemetry.

## What exists

| Thing | Where | Notes |
|---|---|---|
| **CosmoGrav for Mac** | `app/` (SwiftUI, Swift Package) | Main product. Version in `app/VERSION`. |
| **CosmoGrav for Windows** | `windows/CosmoGrav` (WPF, .NET Framework 4.8) | Version in `windows/VERSION`. Fewer features than Mac so far. |
| **CosmoGrav for Chrome** | `extension/` (Manifest V3, no build step) | Ships inside the Mac app and updates with it. Mac only. |
| Installers | `install.sh` (Mac), `install.ps1` (Windows) | One line in Terminal / PowerShell. Also used by the in-app "Update now". |
| CI and releases | `.github/workflows/` | Builds, self-tests and publishes on every push to `main`. |
| Website | private repo `raetori/creation-of-cosmos`, branch **v2** is live | `main` there is an old backup, never deploy it. Pages `/cosmograv`, `/cosmograv/guide`, `/lab`. Its own `HANDOFF.md` has hard design rules. Hosted on Vercel; deploy with `vercel deploy --prod` from v2 on Raeden's Mac. Push straight to v2, no PRs. |
| Other apps | Nova (https://nova.creationofcosmos.com), CosmoDrive (https://drive.creationofcosmos.com) | Listed on the website's Lab page. |
| Claude skills Raeden saved | `new-cosmos-app`, `cosmos-step-guide`, `cosmos-app-guide-pack`, `cosmos-motion-kit`, `cosmos-launch-pack`, `cosmos-guide-to-final` | For making the next app, guides, launch packs and motion ads. |

## Install lines (what users run)

- Mac: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/raetori/ultra-hd-youtube-downloader/main/install.sh)"`
- Windows (PowerShell, not Command Prompt): `irm https://raw.githubusercontent.com/raetori/ultra-hd-youtube-downloader/main/install.ps1 | iex`

## Hard rules for CosmoGrav

1. **Every video must import into Premiere Pro**: H.264 + AAC MP4 (keep the stream if already H.264, else encode with the hardware encoder). ProRes 422 HQ .mov is an option. WebM/AV1 output is never acceptable.
2. **No security warnings on install.** Never ship a browser-downloaded `.app`, `.command` or unsigned `.exe` as the main path. The one-line installers are the official way. The double-click Windows `.exe` installer (PR #5) is not merged: don't link it.
3. Stays a **desktop app**, not a website (YouTube blocks servers; copyright risk). A download page on the website is fine.
4. **No captcha bypass, no file-host wait/limit tricks, no premium accounts, no stored passwords.** The user solves robot checks themselves in the built-in browser.
5. Chrome Web Store is not an option (its policy bans YouTube downloaders). The extension loads unpacked with Developer mode on.
6. Mac bundle id stays `com.creationofcosmos.mediadownloader` so old settings carry over. Support files live in `~/Library/Application Support/TeamYTDownloader/`.
7. YouTube speed: `--extractor-args youtube:formats=dashy -N 8`.

## How releases work

- **Mac**: push to `main` touching `app/**`, `assets/**` or `extension/**` runs `build-app.yml`: compile (arm64 + x86_64), bundle, self-tests, then publish release `v<app/VERSION>`. **Bump `app/VERSION` and `extension/manifest.json` together** (CI fails if they differ) or the app won't offer the update.
- **Windows**: push to `main` touching `windows/**` or `install.ps1` runs `build-windows.yml` and publishes `win-v<windows/VERSION>` (not marked "latest", so Mac updates are unaffected).
- Branches named `preview/**` build and screenshot without releasing. Screenshots and self-test logs go to the `ci-preview` pre-release.
- CI can't reach YouTube (bot-blocked), so tests use locally served media: `--selftest`, `--selftest-import`, `--selftest-crawljob`, `--selftest-files`, `--selftest-page`, `--selftest-bridge`.
- Mac CI runs on `macos-15-intel` because Apple Silicon runners were full (Nov 2026). Intel runners can't draw the GUI, so no screenshots there; move back to `macos-15` when capacity returns.
- `main` is protected against deletion and force pushes. Direct pushes and merges are allowed.

## Look and feel

- CosmoGrav: black with warm gold, ember mono eyebrow labels, thin wide-tracked "CREATION OF COSMOS", cream pill buttons with "→", orb-on-ring loader for progress, eased motion only. Code: `app/Sources/*/Theme.swift`.
- New apps and the website use the **Starlight** look (cool white/blue/violet on near-black, Archivo + IBM Plex Mono). Must not resemble Claude's own branding. Design system: https://claude.ai/artifact/TBPNFQWK5zHR5wWz49KhnY
- Logo is the C-with-orb mark. The orb-on-ring is the loader, never the logo.
- About screen has a founder section (Raeden Toribio, Founder, 21 years editing).

## Feature history (one line per release)

- 1.0 queue, trim, rename, quality, folder picker, 2-3 at once, fast YouTube
- 1.1 ProRes, captions, notifications
- 1.2 website look, hourly update checks, branded About
- 1.3 renamed CosmoGrav; Windows version (win-v1.3.0)
- 1.4 long link-list import (txt/csv/paste, batches, Shorts split); 1.4.1 captions only (SRT)
- 1.5 JDownloader `.crawljob` files and Folder Watch
- 1.6 any file type, Google Drive/Dropbox/OneDrive links, resumable 8-piece downloads; 1.6.1 file-host download pages in a built-in browser
- 1.7 Chrome extension (right-click, hover and YouTube buttons, link grabber) synced with the app
- 1.7.1 Pinterest fixed: ph./other country links and pin.it short links become the www pin, feed/search/profile pages get a clear "open the pin" message instead of a 404, picture pins save the original image, the hover button sends the pin's own link; hover button no longer cropped (`Pinterest.swift`)

## Ideas and open items

- Windows still lacks: list import, `.crawljob`, file downloads, Chrome extension bridge.
- Not built yet: speed limit setting.
- Separate "Cosmos Audio Tools" app (vocal/music split with Demucs): offered, not started.
- Pending design choice: whether new apps use Starlight (recommended) or the warm CosmoGrav look.

## Keeping this file current

**Any Claude (or person) who finishes work on this project updates this file in the same change**, before it lands on `main`:

- New feature or release: add one line to "Feature history".
- New rule, decision or preference from Raeden: add it to the right section, in plain words, with no private details.
- Something finished or dropped: remove it from "Ideas and open items".
- Never edit between the LIVE-STATUS markers; GitHub fills that in.
- Never add email addresses, passwords, tokens, keys, private file paths or anything from a `.env`.

## Live status

<!-- LIVE-STATUS:START (filled in by .github/scripts/update-handoff.py, do not edit by hand) -->
_Last refreshed 2026-11-05 13:33 UTC._

| | In the code (main) | Latest published release |
|---|---|---|
| Mac app | 1.7.1 (`app/VERSION`) | v1.7.0 (2026-11-03) |
| Windows app | 1.3.0 (`windows/VERSION`) | win-v1.3.0 (2026-10-25) |
| Chrome extension | 1.7.1 (`extension/manifest.json`) | ships inside the Mac app |

**Open pull requests**

- #7 Bump actions/checkout from 4 to 7 (branch `dependabot/github_actions/actions/checkout-7`, opened 2026-10-30)
- #6 Bump actions/upload-artifact from 4 to 7 (branch `dependabot/github_actions/actions/upload-artifact-7`, opened 2026-10-30)
- #5 Windows: download-and-double-click installer (CosmoGrav-Setup.exe) (branch `claude/project-thread-v0ezpy`, opened 2026-10-30)

**Last 15 changes on main** (newest first)

- 2026-11-05 `4c89c11` Pinterest: fix 404s from feed and country links, save picture pins, uncrop the hover button
- 2026-11-05 `6150f33` Handoff: leave the bot's own refresh commits out of the change list
- 2026-11-05 `4a3a3d6` Self-updating HANDOFF.md for new Claude chats
- 2026-11-03 `a5556c0` CI: show why the app closes when the launch check fails
- 2026-11-03 `423b0fd` CI: build the Mac app on GitHub's Intel Mac machines
- 2026-11-03 `8c39a3a` CI: build on macos-latest (no macos-15 machine was picking up jobs)
- 2026-11-03 `9cd3dbc` CosmoGrav for Chrome: right-click, hover and YouTube buttons, link grabber, synced with the app
- 2026-10-31 `7119b07` Page self-test: note the download-page state while it lasts
- 2026-10-31 `5121d91` CI: wait for the test page server without tripping bash -e
- 2026-10-31 `8d0e272` Download pages work in the background: wait out the timer, click the free button
- 2026-10-31 `40744ff` Open file-host download pages in a built-in browser and take their download
- 2026-10-31 `eb95ad6` Split the piece plan so the compiler can type-check it
- 2026-10-31 `f59ceb9` Download any file and public Drive, Dropbox and OneDrive links, in resumable pieces
- 2026-10-31 `253d647` Open JDownloader .crawljob files and watch a folder for them
- 2026-10-30 `d31a6ac` README and version 1.4.1 for Captions only (SRT)
<!-- LIVE-STATUS:END -->
