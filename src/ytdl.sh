#!/bin/bash
# YouTube Downloader helper. The app calls this; people never run it directly.
#   ytdl.sh start MODE URL   start a download in the background (MODE: premiere | premiere1080 | audio)
#   ytdl.sh status           print STATE|PERCENT|MESSAGE  (STATE: running | done | error | idle; PERCENT -1 = unknown)
#   ytdl.sh result           print the saved file's path
#   ytdl.sh error            print a short reason for the last failure
#   ytdl.sh cancel           stop the current download and clean up
#   ytdl.sh log              print the path of the full log
#   ytdl.sh convert IN OUT   make a Premiere-ready H.264/AAC MP4 from any video file (used internally)

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

probe() { # probe FILE STREAM FIELD
  "$BIN/ffprobe" -v error -select_streams "$2" -show_entries "$3" -of default=nw=1:nk=1 "$1" | head -1
}

# Premiere imports H.264 + AAC in MP4 reliably; WebM, VP9, AV1 and Opus it does not.
# Streams that are already H.264 (8-bit 4:2:0) or AAC are copied untouched; anything else is re-encoded.
convert() {
  local in="$1" out="$2"
  local vcodec pixfmt acodec height fps dur
  vcodec=$(probe "$in" v:0 stream=codec_name)
  pixfmt=$(probe "$in" v:0 stream=pix_fmt)
  acodec=$(probe "$in" a:0 stream=codec_name)
  height=$(probe "$in" v:0 stream=height)
  fps=$(probe "$in" v:0 stream=avg_frame_rate | awk -F/ '{ if ($2 > 0) printf "%d", $1 / $2; else print 30 }')
  dur=$("$BIN/ffprobe" -v error -show_entries format=duration -of default=nw=1:nk=1 "$in" | cut -d. -f1)
  echo "CONVERT duration=${dur:-0} video=${vcodec:-none}/${pixfmt} audio=${acodec:-none}"

  local vargs=() aargs=()
  if [ -z "$vcodec" ]; then
    vargs=(-vn)
  elif [ "$vcodec" = h264 ] && [ "$pixfmt" = yuv420p ]; then
    vargs=(-c:v copy)
  else
    # Bitrate for Apple's hardware encoder, scaled by resolution and frame rate.
    local mbps=8
    [ "${height:-0}" -gt 720 ] && mbps=16
    [ "${height:-0}" -gt 1080 ] && mbps=30
    [ "${height:-0}" -gt 1440 ] && mbps=60
    [ "${height:-0}" -gt 2160 ] && mbps=120
    [ "${fps:-30}" -gt 30 ] && mbps=$((mbps * 3 / 2))
    vargs=(-c:v h264_videotoolbox -b:v "${mbps}M" -maxrate "$((mbps * 2))M" -bufsize "$((mbps * 2))M" -profile:v high -pix_fmt yuv420p)
  fi
  if [ -z "$acodec" ]; then
    aargs=(-an)
  elif [ "$acodec" = aac ]; then
    aargs=(-c:a copy)
  else
    aargs=(-c:a aac -b:a 320k -ar 48000)
  fi

  local common=(-hide_banner -nostdin -y -i "$in" -map 0:v:0? -map 0:a:0? -map_metadata 0 -dn -sn)
  local tail=(-tag:v avc1 -movflags +faststart -progress "$RUN/ffprogress" -nostats -loglevel error "$out")
  if ! "$BIN/ffmpeg" "${common[@]}" "${vargs[@]}" "${aargs[@]}" "${tail[@]}"; then
    if [ "${vargs[1]}" = h264_videotoolbox ]; then
      # No hardware encoder (old Mac or odd source): fall back to the software H.264 encoder.
      echo "CONVERT fallback=libx264"
      vargs=(-c:v libx264 -preset fast -crf 18 -profile:v high -pix_fmt yuv420p)
      "$BIN/ffmpeg" "${common[@]}" "${vargs[@]}" "${aargs[@]}" "${tail[@]}" || return 1
    else
      return 1
    fi
  fi
  # Confirm the result really is what Premiere wants before calling it done.
  local check
  check=$(probe "$out" v:0 stream=codec_name)
  [ -z "$vcodec" ] || [ "$check" = h264 ] || { echo "ERROR: conversion produced $check instead of H.264"; return 1; }
}

run_job() {
  local mode="$1" url="$2"
  local work="$RUN/tmp"

  # Keep yt-dlp current at most once a day; YouTube changes often and old versions break.
  local stamp="$BASE/last-update"
  if [ -z "$(find "$stamp" -mtime -1 2>/dev/null)" ]; then
    echo "STAGE update"
    "$BIN/yt-dlp" -U && touch "$stamp"
  fi
  echo "STAGE info"

  local args=(
    --ffmpeg-location "$BIN"
    -P "$work"
    -o "%(title).150B [%(id)s].%(ext)s"
    --no-playlist --newline --no-mtime
    --progress-template "download:PCT %(progress._percent_str)s"
    --print-to-file after_move:filepath "$RUN/downloaded"
  )
  [ -x "$BIN/deno" ] && args+=(--js-runtimes "deno:$BIN/deno")

  case "$mode" in
    premiere)
      # Highest resolution available (up to 4K/8K). SDR versions are preferred so HDR videos don't look washed out in Premiere.
      args+=(-f "bv*[dynamic_range=SDR]+ba/bv*+ba/b" --merge-output-format mkv) ;;
    premiere1080)
      # Up to 1080p. YouTube's own H.264 + AAC streams are picked when they exist, so no conversion is needed.
      args+=(-f "bv*[height<=1080][vcodec^=avc1]+ba[acodec^=mp4a]/bv*[height<=1080][dynamic_range=SDR]+ba/bv*[height<=1080]+ba/b[height<=1080]/b" --merge-output-format mkv) ;;
    audio)
      args+=(-f "ba/b" -x --audio-format mp3 --audio-quality 0) ;;
    *)
      echo "ERROR: unknown mode $mode"; return 2 ;;
  esac

  "$BIN/yt-dlp" "${args[@]}" -- "$url" || return 1
  local src
  src=$(tail -1 "$RUN/downloaded" 2>/dev/null)
  [ -f "$src" ] || { echo "ERROR: download finished but the file is missing"; return 1; }

  local name dest
  name=$(basename "$src"); name="${name%.*}"
  mkdir -p "$OUT"
  if [ "$mode" = audio ]; then
    dest="$OUT/$name.mp3"
    mv -f "$src" "$dest" || return 1
  else
    dest="$OUT/$name.mp4"
    echo "STAGE convert"
    convert "$src" "$work/out.mp4" || { echo "ERROR: couldn't convert the video to a Premiere-ready MP4"; return 1; }
    mv -f "$work/out.mp4" "$dest" || return 1
  fi
  echo "$dest" > "$RUN/filepath"
}

case "$1" in
  start)
    if is_running; then echo "busy"; exit 1; fi
    rm -rf "$RUN/tmp" "$RUN/log" "$RUN/exitcode" "$RUN/filepath" "$RUN/downloaded" "$RUN/ffprogress" "$RUN/pid"
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
    last=$(grep -E '^(PCT |STAGE |\[Merger\]|\[ExtractAudio\])' "$log" 2>/dev/null | tail -1)
    parts=$(grep -c '^\[download\] Destination' "$log" 2>/dev/null)
    case "$last" in
      "STAGE update"*)       echo "running|-1|Checking for updates..." ;;
      "STAGE convert"*)
        dur=$(grep -m1 '^CONVERT duration=' "$log" | sed -E 's/^CONVERT duration=([0-9]+).*/\1/')
        us=$(grep '^out_time_us=' "$RUN/ffprogress" 2>/dev/null | tail -1 | cut -d= -f2)
        pct=-1
        if [ "${dur:-0}" -gt 0 ] && [ -n "$us" ] && [ "$us" != N/A ]; then
          pct=$(( us / 10000 / dur )); [ "$pct" -gt 100 ] && pct=100; [ "$pct" -lt 0 ] && pct=-1
        fi
        if grep -q '^CONVERT .*video=h264/yuv420p' "$log"; then msg="Finishing up..."
        else msg="Converting to H.264 for Premiere..."; fi
        [ "$pct" -ge 0 ] && msg="$msg ${pct}%"
        echo "running|$pct|$msg" ;;
      "PCT "*)
        pct=$(echo "$last" | sed -E 's/\x1b\[[0-9;]*m//g; s/[^0-9.]//g; s/\..*//')
        [ -z "$pct" ] && pct=-1
        msg="Downloading... ${pct}%"
        if [ "$(cat "$RUN/mode")" != "audio" ] && [ "$parts" -ge 1 ]; then
          [ "$parts" -ge 2 ] && msg="$msg (audio)" || msg="$msg (video)"
        fi
        echo "running|$pct|$msg" ;;
      "[Merger]"*)           echo "running|-1|Combining video and audio..." ;;
      "[ExtractAudio]"*)     echo "running|-1|Converting to MP3..." ;;
      *)                     echo "running|-1|Getting video info..." ;;
    esac
    ;;

  result)
    tail -1 "$RUN/filepath" 2>/dev/null ;;

  error)
    msg=$(grep -E '^ERROR:' "$RUN/log" 2>/dev/null | tail -1 | sed -E 's/^ERROR: (\[[^]]*\] )?([A-Za-z0-9_-]{11}: )?//; s/ \(caused by .*//')
    [ -z "$msg" ] && msg=$(tail -1 "$RUN/log" 2>/dev/null)
    echo "${msg:-Unknown error}" | cut -c1-300 ;;

  cancel)
    [ -f "$RUN/pid" ] && killtree "$(cat "$RUN/pid")"
    sleep 1
    rm -rf "$RUN/tmp" "$RUN/pid"
    echo cancelled ;;

  log)
    echo "$RUN/log" ;;

  convert)
    convert "$2" "$3" ;;

  *)
    echo "usage: ytdl.sh start|status|result|error|cancel|log|convert"; exit 2 ;;
esac
