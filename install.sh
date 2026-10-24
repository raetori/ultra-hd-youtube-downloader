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
#!/bin/bash
# YouTube Downloader helper. The app calls this; people never run it directly.
#   ytdl.sh start MODE URL   start a download in the background (MODE: best | premiere | premiere4k | audio)
#   ytdl.sh status           print STATE|PERCENT|MESSAGE  (STATE: running | done | error | idle; PERCENT -1 = unknown)
#   ytdl.sh result           print the saved file's path
#   ytdl.sh error            print a short reason for the last failure
#   ytdl.sh cancel           stop the current download and clean up
#   ytdl.sh log              print the path of the full log

BASE="${TEAMYT_HOME:-$HOME/Library/Application Support/TeamYTDownloader}"
BIN="$BASE/bin"
RUN="$BASE/run"
OUT="${TEAMYT_OUT:-$HOME/Downloads}"
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$RUN"

killtree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do killtree "$child"; done
  kill -TERM "$1" 2>/dev/null
}

is_running() {
  [ -f "$RUN/pid" ] && [ ! -f "$RUN/exitcode" ] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null
}

run_job() {
  local mode="$1" url="$2"

  # Keep yt-dlp current at most once a day; YouTube changes often and old versions break.
  local stamp="$BASE/last-update"
  if [ -z "$(find "$stamp" -mtime -1 2>/dev/null)" ]; then
    echo "STAGE update"
    "$BIN/yt-dlp" -U && touch "$stamp"
  fi
  echo "STAGE info"

  local args=(
    --ffmpeg-location "$BIN"
    -P "$OUT" -P "temp:$RUN/tmp"
    -o "%(title).150B [%(id)s].%(ext)s"
    --no-playlist --newline --force-overwrites --no-mtime
    --progress-template "download:PCT %(progress._percent_str)s"
    --print-to-file after_move:filepath "$RUN/filepath"
  )
  [ -x "$BIN/deno" ] && args+=(--js-runtimes "deno:$BIN/deno")

  case "$mode" in
    best)
      # Highest resolution and bitrate YouTube has, in its original codec (often VP9/AV1, .webm/.mkv).
      args+=(-f "bv*+ba/b") ;;
    premiere)
      # Native H.264 + AAC streams, no re-encode. YouTube only offers H.264 up to 1080p.
      args+=(-f "bv*[vcodec^=avc1]+ba[acodec^=mp4a]/b[vcodec^=avc1]/bv*+ba/b" --merge-output-format mp4) ;;
    premiere4k)
      # Best stream (up to 4K/8K) re-encoded to H.264 + AAC. Merging to mkv first forces the re-encode.
      args+=(-f "bv*+ba/b" --merge-output-format mkv --recode-video mp4
             --postprocessor-args "VideoConvertor:-c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -c:a aac -b:a 320k -movflags +faststart") ;;
    audio)
      args+=(-f "ba/b" -x --audio-format mp3 --audio-quality 0) ;;
    *)
      echo "ERROR: unknown mode $mode"; return 2 ;;
  esac

  "$BIN/yt-dlp" "${args[@]}" -- "$url"
}

case "$1" in
  start)
    if is_running; then echo "busy"; exit 1; fi
    rm -rf "$RUN/tmp" "$RUN/log" "$RUN/exitcode" "$RUN/filepath" "$RUN/pid"
    mkdir -p "$RUN/tmp"
    echo "$2" > "$RUN/mode"
    (
      run_job "$2" "$3"
      code=$?
      rm -rf "$RUN/tmp"
      echo "$code" > "$RUN/exitcode"
    ) > "$RUN/log" 2>&1 < /dev/null &
    echo $! > "$RUN/pid"
    echo started
    ;;

  status)
    if [ ! -f "$RUN/pid" ]; then echo "idle|-1|"; exit 0; fi
    if [ -f "$RUN/exitcode" ]; then
      if [ "$(cat "$RUN/exitcode")" = "0" ] && [ -s "$RUN/filepath" ]; then echo "done|100|Finished"
      else echo "error|-1|Download failed"; fi
      exit 0
    fi
    if ! kill -0 "$(cat "$RUN/pid")" 2>/dev/null; then echo "error|-1|Download stopped unexpectedly"; exit 0; fi

    log="$RUN/log"
    last=$(grep -E '^(PCT |STAGE |\[Merger\]|\[VideoConvertor\]|\[ExtractAudio\]|\[FixupM3u8\]|\[download\] Destination)' "$log" 2>/dev/null | grep -v '^\[download\] Destination' | tail -1)
    parts=$(grep -c '^\[download\] Destination' "$log" 2>/dev/null)
    case "$last" in
      "STAGE update"*)       echo "running|-1|Checking for updates..." ;;
      "PCT "*)
        pct=$(echo "$last" | sed -E 's/\x1b\[[0-9;]*m//g; s/[^0-9.]//g; s/\..*//')
        [ -z "$pct" ] && pct=-1
        msg="Downloading... ${pct}%"
        if [ "$(cat "$RUN/mode")" != "audio" ] && [ "$parts" -ge 1 ]; then
          [ "$parts" -ge 2 ] && msg="$msg (audio)" || msg="$msg (video)"
        fi
        echo "running|$pct|$msg" ;;
      "[Merger]"*)           echo "running|-1|Combining video and audio..." ;;
      "[VideoConvertor]"*)   echo "running|-1|Converting to Premiere-ready MP4. Long or 4K videos can take a while..." ;;
      "[ExtractAudio]"*)     echo "running|-1|Converting to MP3..." ;;
      *)                     echo "running|-1|Getting video info..." ;;
    esac
    ;;

  result)
    tail -1 "$RUN/filepath" 2>/dev/null ;;

  error)
    msg=$(grep -E '^ERROR:' "$RUN/log" 2>/dev/null | tail -1 | sed -E 's/^ERROR: (\[[^]]*\] )?([A-Za-z0-9_-]{11}: )?//')
    [ -z "$msg" ] && msg=$(tail -1 "$RUN/log" 2>/dev/null)
    echo "${msg:-Unknown error}" | cut -c1-300 ;;

  cancel)
    [ -f "$RUN/pid" ] && killtree "$(cat "$RUN/pid")"
    sleep 1
    rm -rf "$RUN/tmp" "$RUN/pid"
    echo cancelled ;;

  log)
    echo "$RUN/log" ;;

  *)
    echo "usage: ytdl.sh start|status|result|error|cancel|log"; exit 2 ;;
esac
__YTDL_HELPER__
chmod +x "$BASE/ytdl.sh"

cat > "$TMP/app.applescript" <<'__APPLESCRIPT__'
-- YouTube Downloader: the app teammates open. The installer compiles this with osacompile.
-- Keep this file plain ASCII so osacompile reads it the same on every Mac.

property appTitle : "YouTube Downloader"

on run
	set helper to quoted form of ((POSIX path of (path to home folder)) & "Library/Application Support/TeamYTDownloader/ytdl.sh")
	set choices to {"Best quality (original file, up to 4K/8K)", "Premiere-ready MP4, fast (up to 1080p)", "Premiere-ready MP4, full quality (up to 4K, slower)", "Audio only (MP3)"}
	set modes to {"best", "premiere", "premiere4k", "audio"}

	repeat
		-- 1. Ask for the link, pre-filled from the clipboard when it holds one.
		set defaultURL to ""
		try
			set clip to (the clipboard as text)
			if clip starts with "http" and (length of clip) < 500 then set defaultURL to clip
		end try
		try
			set dlg to display dialog "Paste a YouTube link:" & return & return & "Only download videos your team has the rights to use." default answer defaultURL with title appTitle buttons {"Cancel", "Next"} default button "Next" cancel button "Cancel" with icon note
		on error number -128
			return
		end try
		set theURL to do shell script "printf %s " & quoted form of (text returned of dlg) & " | tr -d '[:space:]'"
		if theURL does not start with "http" then
			display dialog "That doesn't look like a link. Copy the address from your browser and try again." with title appTitle buttons {"OK"} default button "OK" with icon caution
		else
			-- 2. Pick a format.
			set picked to choose from list choices with title appTitle with prompt "How do you want it saved? Files go to your Downloads folder." default items {item 2 of choices} OK button name "Download" cancel button name "Cancel"
			if picked is false then return
			set mode to "best"
			repeat with i from 1 to count of choices
				if (item i of choices) is (item 1 of picked) then set mode to item i of modes
			end repeat

			-- 3. Download, showing progress until the helper reports done or error.
			set started to do shell script helper & " start " & mode & " " & quoted form of theURL
			if started is "busy" then
				display dialog "Another download is still running. Wait for it to finish, then try again." with title appTitle buttons {"OK"} default button "OK" with icon caution
				return
			end if
			set progress total steps to -1
			set progress completed steps to 0
			set progress description to "Starting..."
			set progress additional description to theURL
			set state to "running"
			try
				repeat while state is "running"
					delay 0.5
					set AppleScript's text item delimiters to "|"
					set parts to text items of (do shell script helper & " status")
					set AppleScript's text item delimiters to ""
					set state to item 1 of parts
					set pct to (item 2 of parts) as integer
					if pct < 0 then
						set progress total steps to -1
					else
						set progress total steps to 100
						set progress completed steps to pct
					end if
					set progress description to item 3 of parts
				end repeat
			on error number -128
				do shell script helper & " cancel"
				return
			end try
			set progress total steps to 0
			set progress description to ""
			set progress additional description to ""

			-- 4. Report the result.
			if state is "done" then
				set savedPath to do shell script helper & " result"
				set savedName to do shell script "basename " & quoted form of savedPath
				set answer to button returned of (display dialog "Saved to your Downloads folder:" & return & return & savedName with title appTitle buttons {"Show in Finder", "Download Another", "Done"} default button "Download Another" with icon note)
				if answer is "Show in Finder" then
					do shell script "open -R " & quoted form of savedPath
					return
				else if answer is "Done" then
					return
				end if
			else
				set reason to do shell script helper & " error"
				set answer to button returned of (display dialog "The download didn't work:" & return & return & reason & return & return & "Check the link and try again in a minute. If it keeps failing, send the log to whoever set this up." with title appTitle buttons {"Open Log", "Try Again", "Close"} default button "Try Again" with icon stop)
				if answer is "Open Log" then
					do shell script "open -e \"$(" & helper & " log)\""
					return
				else if answer is "Close" then
					return
				end if
			end if
		end if
	end repeat
end run
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
