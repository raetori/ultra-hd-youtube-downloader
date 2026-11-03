# CosmoGrav for Chrome

The browser half of CosmoGrav. It ships inside the Mac app (`CosmoGrav.app/Contents/Resources/ChromeExtension`) and the app copies it to `~/Library/Application Support/CosmoGrav/Chrome Extension`, which is the folder people load into Chrome once.

## How it talks to the app

- Chrome native messaging, host `com.creationofcosmos.cosmograv`. The app writes the host manifest for every Chrome-based browser it finds, pointing at its own executable, with `allowed_origins` set to this extension only. The id `bkpidlfkklifiknphemnicbhdfnidmhj` is fixed by the public `key` in `manifest.json` (no private key is kept or needed for an unpacked extension).
- Messages: `hello` (version handshake, copies a newer bundled extension into place), `status` (queue summary from `browser-status.json`, which the open app refreshes every 3 s), `add` (links, quality, start, clip `from`/`to`, `mode` queue or import), `open` (app or downloads folder).
- `add` writes a private (0600) request file into `TeamYTDownloader/browser-inbox` and opens `cosmograv://inbox`; the app validates it again before adding.

## Staying in sync with the app

`app/bundle.sh` stamps `manifest.json` with `app/VERSION`, and CI fails if the two differ in the repo. On every hello (startup, hourly, every popup open) the extension compares the app's bundled version with its own; when the app's is newer it calls `chrome.runtime.reload()` once for that version, which loads the new files the app just copied.

Why not the Chrome Web Store: its policy doesn't allow extensions that download from YouTube, and a store listing would also need a developer account and review for every release. Shipping with the app keeps both always on the same version.

## Permissions

`contextMenus`, `nativeMessaging`, `storage`, `activeTab`, `scripting`, `alarms`; content scripts only on YouTube. Optional and asked for only when used: all sites (hover button elsewhere) and `tabs` (Send all tabs). No remote code, no fonts or scripts from the internet, no analytics.

## Release zip

Each release also has `CosmoGrav-Chrome-Extension.zip` for people who want to look at it, but the copy the app installs is the one that updates itself.
