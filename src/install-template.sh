#!/bin/bash
# Install YouTube Downloader: sets up yt-dlp, ffmpeg and Deno in your user folder and builds the app.
# No Homebrew, no admin password. Safe to run again to repair or update.

set -u
APP_NAME="YouTube Downloader"
BASE="$HOME/Library/Application Support/TeamYTDownloader"
BIN="$BASE/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mSetup failed: %s\033[0m\n' "$*"; printf 'Send a screenshot of this window to whoever shared the installer.\n\n'; exit 1; }
fetch() { curl -fL --retry 3 --connect-timeout 20 --progress-bar -o "$2" "$1"; }

clear
cat <<'EOF'
==============================================
   YouTube Downloader setup
==============================================
This takes 1-3 minutes and only needs to be done once.
Reminder: only download videos your team has the rights to use.
EOF

[ "$(uname -s)" = "Darwin" ] || fail "this installer is for Macs only."
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then ARCH=arm64; else ARCH=x86_64; fi
mkdir -p "$BIN" || fail "couldn't create $BIN"

say "1/4  Downloading yt-dlp (the downloader)..."
fetch "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" "$TMP/yt-dlp" || fail "couldn't download yt-dlp. Check your internet connection."
chmod +x "$TMP/yt-dlp" && mv -f "$TMP/yt-dlp" "$BIN/yt-dlp"
"$BIN/yt-dlp" --version >/dev/null 2>&1 || fail "yt-dlp downloaded but won't run."
touch "$BASE/last-update"

say "2/4  Getting ffmpeg (combines and converts video)..."
ffmpeg_ok() { "$BIN/ffmpeg" -version >/dev/null 2>&1 && "$BIN/ffprobe" -version >/dev/null 2>&1; }
rm -f "$BIN/ffmpeg" "$BIN/ffprobe"
for dir in /opt/homebrew/bin /usr/local/bin; do
  # Reuse a Homebrew ffmpeg if this Mac already has one.
  if [ -x "$dir/ffmpeg" ] && [ -x "$dir/ffprobe" ] && "$dir/ffmpeg" -version >/dev/null 2>&1; then
    ln -sf "$dir/ffmpeg" "$BIN/ffmpeg"; ln -sf "$dir/ffprobe" "$BIN/ffprobe"; echo "Using the ffmpeg already installed in $dir"; break
  fi
done
if ! ffmpeg_ok; then
  rm -f "$BIN/ffmpeg" "$BIN/ffprobe"
  if [ "$ARCH" = arm64 ]; then mr=arm64; else mr=amd64; fi
  for tool in ffmpeg ffprobe; do
    rm -rf "${TMP:?}/$tool" && mkdir -p "$TMP/$tool"
    if ! fetch "https://ffmpeg.martin-riedl.de/redirect/latest/macos/$mr/release/$tool.zip" "$TMP/$tool.zip"; then
      # Intel-only fallback mirror.
      [ "$ARCH" = x86_64 ] && fetch "https://evermeet.cx/ffmpeg/getrelease/$tool/zip" "$TMP/$tool.zip"
    fi
    unzip -qo "$TMP/$tool.zip" -d "$TMP/$tool" 2>/dev/null
    found=$(find "$TMP/$tool" -type f -name "$tool" | head -1)
    [ -n "$found" ] && mv -f "$found" "$BIN/$tool" && chmod +x "$BIN/$tool"
  done
fi
xattr -c "$BIN"/* 2>/dev/null
ffmpeg_ok || fail "couldn't set up ffmpeg. Check your internet connection and run the installer again."

say "3/4  Getting Deno (yt-dlp needs it for YouTube)..."
if [ "$ARCH" = arm64 ]; then deno_zip=deno-aarch64-apple-darwin.zip; else deno_zip=deno-x86_64-apple-darwin.zip; fi
if fetch "https://github.com/denoland/deno/releases/latest/download/$deno_zip" "$TMP/deno.zip" && unzip -qo "$TMP/deno.zip" -d "$TMP/deno"; then
  mv -f "$TMP/deno/deno" "$BIN/deno" && chmod +x "$BIN/deno" && xattr -c "$BIN/deno" 2>/dev/null
fi
"$BIN/deno" --version >/dev/null 2>&1 || echo "Warning: Deno didn't install. Downloads may be limited to lower quality."

say "4/4  Building the app..."
cat > "$BASE/ytdl.sh" <<'__YTDL_HELPER__'
@@YTDL_SH@@
__YTDL_HELPER__
chmod +x "$BASE/ytdl.sh"

cat > "$TMP/app.applescript" <<'__APPLESCRIPT__'
@@APP_APPLESCRIPT@@
__APPLESCRIPT__

if [ -w /Applications ]; then APPS=/Applications; else APPS="$HOME/Applications"; mkdir -p "$APPS"; fi
APP="$APPS/$APP_NAME.app"
rm -rf "$APP"
osacompile -o "$APP" "$TMP/app.applescript" || fail "couldn't build the app."
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist" 2>/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.team.youtubedownloader" "$APP/Contents/Info.plist" 2>/dev/null

say "All set!"
cat <<EOF
"$APP_NAME" is now in your $( [ "$APPS" = /Applications ] && echo "Applications folder" || echo "Applications folder (inside your home folder)" ).
Open it from Launchpad or Spotlight (Cmd + Space, type "YouTube Downloader").
Tip: drag it to your Dock for one-click access.

Opening it now... You can close this window.
EOF
open "$APP"
