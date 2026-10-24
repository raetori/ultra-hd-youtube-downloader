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
