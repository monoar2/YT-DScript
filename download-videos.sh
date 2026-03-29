#!/bin/bash

# YouTube Channel Downloader for Jellyfin - OPTIMIZED FOR SPEED
# Downloads YouTube channels and organizes them for Jellyfin TV show library

# ---- Desktop notifications (cron-safe) ----
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
export DISPLAY=":0"

# ---- Determine config file path ----
if [ -n "$1" ]; then
    CONFIG_FILE="$1"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CONFIG_FILE="$SCRIPT_DIR/config.json"
fi

# ---- Logging helper ----
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
logn() { echo "$*"; }  # no timestamp, for headers/separators

# ---- Dependency checks ----
for cmd in yt-dlp jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Dependency missing: $cmd"
        exit 1
    fi
done

[ ! -f "$CONFIG_FILE" ] && echo "❌ Config file not found: $CONFIG_FILE" && exit 1

RUN_START=$(date +%s)
RUN_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

logn "========================================"
log "🚀 Run started: $RUN_TIMESTAMP"
log "📋 Loading configuration from: $CONFIG_FILE"

# ---- Read configuration from the config file ----
ROOT_DIR=$(jq -r '.root_directory // "/media/youtube"' "$CONFIG_FILE")
DELAY=$(jq -r '.delay // 2' "$CONFIG_FILE")
CREATE_NFO_FILES=$(jq -r '.create_nfo_files // false' "$CONFIG_FILE")
FORCE_CODEC_COMPATIBILITY=$(jq -r '.force_codec_compatibility // false' "$CONFIG_FILE")
MAX_VIDEOS_PER_CHANNEL=$(jq -r '.max_videos_per_channel // 50' "$CONFIG_FILE")
DOWNLOAD_SUBTITLES=$(jq -r '.download_subtitles // false' "$CONFIG_FILE")
VIDEO_QUALITY=$(jq -r '.video_quality // "best[height<=720]"' "$CONFIG_FILE")
SKIP_FAILED=$(jq -r '.skip_failed_channels // true' "$CONFIG_FILE")
OUTPUT_TEMPLATE=$(jq -r '.output_template // "Season 01/%(upload_date)s - %(title)s [%(id)s].%(ext)s"' "$CONFIG_FILE")
USE_COOKIES=$(jq -r '.use_cookies // true' "$CONFIG_FILE")
COOKIES_FILE=$(jq -r '.cookies_file // "cookies.txt"' "$CONFIG_FILE")

# ---- Stall detection settings (override in config.json if needed) ----
# stall_timeout     : seconds without download progress before declaring a stall
# stall_retry_wait  : seconds to wait after a stall before retrying
# stall_max_retries : max retry attempts per channel before giving up
STALL_TIMEOUT=$(jq -r '.stall_timeout // 300' "$CONFIG_FILE")
STALL_RETRY_WAIT=$(jq -r '.stall_retry_wait // 600' "$CONFIG_FILE")
STALL_MAX_RETRIES=$(jq -r '.stall_max_retries // 3' "$CONFIG_FILE")

# ---- Fix cookie file path ----
if [ "$USE_COOKIES" = "true" ]; then
    CONFIG_DIR=$(dirname "$CONFIG_FILE")
    if [[ "$COOKIES_FILE" != /* ]]; then
        COOKIES_FILE="$CONFIG_DIR/$COOKIES_FILE"
    fi
fi

log "📁 Root directory: $ROOT_DIR"
log "⏱️  Delay between channels: ${DELAY}s"
log "🎬 Max videos per channel: $MAX_VIDEOS_PER_CHANNEL"
log "📺 Video quality: $VIDEO_QUALITY"
log "🔄 Skip failed channels: $SKIP_FAILED"
log "🍪 Use cookies: $USE_COOKIES"
log "🛡️  Stall detection: timeout=${STALL_TIMEOUT}s | retry_wait=${STALL_RETRY_WAIT}s | max_retries=$STALL_MAX_RETRIES"
log "⚡ OPTIMIZED FOR SPEED"

# Check if cookies file exists
if [ "$USE_COOKIES" = "true" ]; then
    if [ -f "$COOKIES_FILE" ]; then
        log "✅ Cookies file found: $COOKIES_FILE"
    else
        log "❌ Cookies file not found: $COOKIES_FILE"
        log "   Downloading without cookies (may be slower)"
        USE_COOKIES="false"
    fi
fi

# Create root directory if it doesn't exist
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR" || {
    echo "❌ Failed to change to root directory: $ROOT_DIR"
    exit 1
}

# ---- Update yt-dlp to nightly ----
log "🔄 Updating yt-dlp to nightly build..."
yt-dlp --update-to nightly --no-warnings 2>/dev/null || log "⚠️ yt-dlp update may have failed, continuing..."

# ---- Get channels array ----
CHANNEL_COUNT=$(jq '.channels | length' "$CONFIG_FILE")

if [ "$CHANNEL_COUNT" -eq 0 ]; then
    echo "⚠️ No channels configured in $CONFIG_FILE"
    exit 0
fi

echo "📺 Found $CHANNEL_COUNT channel(s) to process"
echo "========================================"

SUCCESS_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
TOTAL_NEW_VIDEOS=0
RATE_LIMIT_EVENTS=0

# Per-channel result tracking (parallel arrays)
declare -a CH_NAMES CH_VIDEOS CH_STATUS CH_ELAPSED CH_SIZE CH_STALLS

# ---- Stall detection wrapper ----
# Runs yt-dlp in the background and monitors directory size every 60s.
# If no growth is seen for STALL_TIMEOUT seconds, kills yt-dlp, waits
# STALL_RETRY_WAIT seconds, then retries up to STALL_MAX_RETRIES times.
# Sets global _LAST_STALLS to the number of stalls that occurred.
run_with_stall_detection() {
    local channel_dir="$1"
    local max_retries="$2"
    shift 2
    local yt_dlp_args=("$@")

    local channel_stalls=0
    local attempt=0
    local stalled=true  # initialize true so the while loop is entered
    local final_exit_code=1

    while $stalled && [ $attempt -lt $max_retries ]; do
        attempt=$((attempt + 1))
        stalled=false

        [ $attempt -gt 1 ] && log "   🔄 Retry attempt $attempt/$max_retries..."

        # Run yt-dlp as its own process group so we can kill all child processes
        setsid yt-dlp "${yt_dlp_args[@]}" &
        local YT_DLP_PID=$!
        local stall_seconds=0
        local last_size
        last_size=$(du -sb "$channel_dir" 2>/dev/null | cut -f1)
        last_size=${last_size:-0}

        # Monitor loop: wake every 60s and check for progress
        while kill -0 $YT_DLP_PID 2>/dev/null; do
            sleep 60
            # Process may have finished during our sleep
            if ! kill -0 $YT_DLP_PID 2>/dev/null; then
                break
            fi

            local current_size
            current_size=$(du -sb "$channel_dir" 2>/dev/null | cut -f1)
            current_size=${current_size:-0}

            if [ "$current_size" -le "$last_size" ]; then
                stall_seconds=$((stall_seconds + 60))
                echo "   ⏸️  [$(date '+%H:%M:%S')] No progress for ${stall_seconds}s (possible rate limit)..."
                if [ $stall_seconds -ge $STALL_TIMEOUT ]; then
                    echo "   🛑 [$(date '+%H:%M:%S')] Stall confirmed! Killing yt-dlp, waiting ${STALL_RETRY_WAIT}s..."
                    # Kill the entire process group (yt-dlp + ffmpeg children)
                    kill -- -$YT_DLP_PID 2>/dev/null || kill $YT_DLP_PID 2>/dev/null
                    wait $YT_DLP_PID 2>/dev/null
                    channel_stalls=$((channel_stalls + 1))
                    RATE_LIMIT_EVENTS=$((RATE_LIMIT_EVENTS + 1))
                    stalled=true
                    break
                fi
            else
                stall_seconds=0
                last_size=$current_size
            fi
        done

        if ! $stalled; then
            # yt-dlp finished naturally — capture its exit code
            wait $YT_DLP_PID
            final_exit_code=$?
        elif [ $attempt -lt $max_retries ]; then
            echo "   ⏳ [$(date '+%H:%M:%S')] Sleeping ${STALL_RETRY_WAIT}s before retry..."
            sleep $STALL_RETRY_WAIT
        else
            echo "   ❌ [$(date '+%H:%M:%S')] Max retries ($max_retries) reached after $channel_stalls stall(s)"
        fi
    done

    _LAST_STALLS=$channel_stalls
    return $final_exit_code
}

# ---- Helper: format bytes to human-readable ----
format_bytes() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.1f GB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.1f KB\", $bytes/1024}"
    else
        echo "${bytes} B"
    fi
}

# ---- Generate tvshow.nfo for Jellyfin YouTube metadata plugin ----
# Reads channel_id and title from the first available episode .info.json.
# The ankenyr Jellyfin plugin uses <uniqueid type="youtube"> to fetch channel art.
generate_channel_metadata() {
    local channel_dir="$1"
    local channel_name="$2"
    local nfo_file="$channel_dir/tvshow.nfo"

    [ -f "$nfo_file" ] && return 0  # already exists, skip

    local info_json
    info_json=$(find "$channel_dir/Season 01" -name "*.info.json" 2>/dev/null | head -1)
    [ -z "$info_json" ] && return 0

    local ch_title ch_id
    ch_title=$(jq -r '.channel // .uploader // ""' "$info_json")
    ch_id=$(jq -r '.channel_id // ""' "$info_json")

    [ -z "$ch_id" ] && return 0

    log "   📄 Writing tvshow.nfo (channel_id: $ch_id)..."
    cat > "$nfo_file" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<tvshow>
    <title>${ch_title}</title>
    <sorttitle>${ch_title}</sorttitle>
    <uniqueid type="youtube" default="true">${ch_id}</uniqueid>
    <plot>YouTube channel: ${ch_title}</plot>
    <studio>YouTube</studio>
    <tag>YouTube</tag>
</tvshow>
EOF
}

# ---- Remove sidecar files that have no matching video file ----
cleanup_orphan_sidecars() {
    local season_dir="$1"
    [ ! -d "$season_dir" ] && return 0

    local count=0
    while IFS= read -r sidecar; do
        local base
        case "$sidecar" in
            *.info.json)  base="${sidecar%.info.json}" ;;
            *.description) base="${sidecar%.description}" ;;
            *.webp)       base="${sidecar%.webp}" ;;
            *.jpg)        base="${sidecar%.jpg}" ;;
            *)            continue ;;
        esac
        # Keep sidecar if any video format with same stem exists
        if ! compgen -G "${base}.mp4" "${base}.mkv" "${base}.webm" "${base}.avi" > /dev/null 2>&1; then
            rm -f "$sidecar"
            count=$((count + 1))
        fi
    done < <(find "$season_dir" -maxdepth 1 \
        \( -name "*.info.json" -o -name "*.description" -o -name "*.webp" -o -name "*.jpg" \) \
        2>/dev/null)

    [ "$count" -gt 0 ] && log "   🧹 Removed $count orphan sidecar file(s) from $(basename "$season_dir")"
}

for ((i=0; i<CHANNEL_COUNT; i++)); do
    echo ""
    CHANNEL_URL=$(jq -r ".channels[$i].url" "$CONFIG_FILE")
    CHANNEL_NAME_OVERRIDE=$(jq -r ".channels[$i].name // empty" "$CONFIG_FILE")
    FETCH_ONLY_NEW=$(jq -r ".channels[$i].fetch_only_new // false" "$CONFIG_FILE")
    CHANNEL_MAX_VIDEOS=$(jq -r ".channels[$i].max_videos // $MAX_VIDEOS_PER_CHANNEL" "$CONFIG_FILE")
    CHANNEL_ENABLED=$(jq -r ".channels[$i].enabled // true" "$CONFIG_FILE")

    # Skip disabled channels
    if [ "$CHANNEL_ENABLED" = "false" ]; then
        log "⏭️  Skipping disabled channel: $CHANNEL_NAME_OVERRIDE"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        CH_NAMES+=("$CHANNEL_NAME_OVERRIDE")
        CH_VIDEOS+=(0)
        CH_STATUS+=("skipped")
        CH_ELAPSED+=(0)
        CH_SIZE+=("—")
        CH_STALLS+=(0)
        continue
    fi

    # Use custom name if provided, otherwise extract from URL
    if [ -n "$CHANNEL_NAME_OVERRIDE" ]; then
        CHANNEL_NAME="$CHANNEL_NAME_OVERRIDE"
    else
        CHANNEL_NAME=$(echo "$CHANNEL_URL" | sed 's|.*/@|@|; s|/.*||; s/[^a-zA-Z0-9._@-]/-/g')
    fi

    # Ensure /videos tab if it's a channel URL
    if [[ "$CHANNEL_URL" =~ @[a-zA-Z0-9_-]+$ ]]; then
        CHANNEL_URL="${CHANNEL_URL}/videos"
    fi

    CHANNEL_DIR="$ROOT_DIR/$CHANNEL_NAME"
    mkdir -p "$CHANNEL_DIR"
    ARCHIVE_FILE="$CHANNEL_DIR/downloaded.txt"

    logn ""
    logn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "🎬 [$((i+1))/$CHANNEL_COUNT] $CHANNEL_NAME"
    log "   📍 URL: $CHANNEL_URL"

    ARCHIVE_LINES_BEFORE=0
    if [ -f "$ARCHIVE_FILE" ]; then
        ARCHIVE_LINES_BEFORE=$(wc -l < "$ARCHIVE_FILE" 2>/dev/null || echo 0)
        log "   📊 Previously downloaded: $ARCHIVE_LINES_BEFORE videos"
    fi

    DIR_SIZE_BEFORE=$(du -sb "$CHANNEL_DIR" 2>/dev/null | cut -f1)
    DIR_SIZE_BEFORE=${DIR_SIZE_BEFORE:-0}

    mkdir -p "$CHANNEL_DIR/Season 01"

    if [ "$FETCH_ONLY_NEW" = "true" ] && [ -f "$ARCHIVE_FILE" ] && [ -s "$ARCHIVE_FILE" ]; then
        log "   🔄 Mode: fetch-only-new (break on existing)"
        BREAK_FLAG="--break-on-existing"
    else
        log "   📦 Mode: initial bulk download (max $CHANNEL_MAX_VIDEOS videos)"
        BREAK_FLAG=""
    fi

    # ---- Build OPTIMIZED yt-dlp command for SPEED ----
    YT_DLP_ARGS=(
        --yes-playlist
        --ignore-errors
        --continue
        --no-overwrites
        --download-archive "downloaded.txt"
        --format "$VIDEO_QUALITY"
        --merge-output-format mp4
        --remux-video mp4
        --concurrent-fragments 5
        --fragment-retries 10
        --retries 10
        --retry-sleep fragment:2
        --sleep-interval 5
        --max-sleep-interval 30
        --throttled-rate 1M
        --write-info-json
        --write-description
        --write-thumbnail
        --convert-thumbnails jpg
        --embed-thumbnail
        --embed-metadata
        --add-metadata
        --parse-metadata "%(upload_date)s:%(meta_date)s"
        --output "$OUTPUT_TEMPLATE"
        $BREAK_FLAG
        --playlist-end "$CHANNEL_MAX_VIDEOS"
        --extractor-args "youtube:player_client=web,mweb"
        --limit-rate 10M
        --force-ipv4
        --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        --referer "https://www.youtube.com/"
        --no-part
        --progress
        --newline
        # Optional: Add external downloader for even more speed
        # --downloader aria2c
        # --downloader-args "aria2c:-x 16 -s 16 -k 1M"
    )

    if [ "$USE_COOKIES" = "true" ]; then
        YT_DLP_ARGS+=(--cookies "$COOKIES_FILE")
        log "   🍪 Using cookies"
    else
        log "   ⚠️  No cookies — downloads may be slower"
    fi

    if [ "$DOWNLOAD_SUBTITLES" = "true" ]; then
        YT_DLP_ARGS+=(--write-subs --sub-langs "en" --convert-subs srt --embed-subs)
        log "   📝 Subtitles enabled"
    fi

    if [ "$FORCE_CODEC_COMPATIBILITY" = "true" ]; then
        YT_DLP_ARGS+=(--recode-video mp4 --audio-codec aac --video-codec h264)
        log "   🔄 Codec compatibility mode"
    fi

    YT_DLP_ARGS+=("$CHANNEL_URL")

    cd "$CHANNEL_DIR" || {
        log "❌ Failed to change to channel directory: $CHANNEL_DIR"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        CH_NAMES+=("$CHANNEL_NAME")
        CH_VIDEOS+=(0)
        CH_STATUS+=("dir error")
        CH_ELAPSED+=(0)
        CH_SIZE+=("—")
        CH_STALLS+=(0)
        continue
    }

    log "   ⚡ Starting download (stall detection: every 60s, timeout ${STALL_TIMEOUT}s)..."
    START_TIME=$(date +%s)
    _LAST_STALLS=0

    run_with_stall_detection "$CHANNEL_DIR" "$STALL_MAX_RETRIES" "${YT_DLP_ARGS[@]}"
    DOWNLOAD_EXIT_CODE=$?

    END_TIME=$(date +%s)
    ELAPSED_TIME=$((END_TIME - START_TIME))
    CHANNEL_STALL_COUNT=$_LAST_STALLS

    DIR_SIZE_AFTER=$(du -sb "$CHANNEL_DIR" 2>/dev/null | cut -f1)
    DIR_SIZE_AFTER=${DIR_SIZE_AFTER:-0}
    BYTES_DOWNLOADED=$((DIR_SIZE_AFTER - DIR_SIZE_BEFORE))
    SIZE_LABEL=$(format_bytes "$BYTES_DOWNLOADED")

    cd "$ROOT_DIR" || log "⚠️ Warning: Could not return to root directory"

    # ---- Post-download: Jellyfin metadata & sidecar cleanup ----
    generate_channel_metadata "$CHANNEL_DIR" "$CHANNEL_NAME"
    cleanup_orphan_sidecars "$CHANNEL_DIR/Season 01"

    # ---- Post-download handling ----
    if [ $DOWNLOAD_EXIT_CODE -eq 101 ]; then
        log "   ✅ Already up-to-date (no new videos)"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        CH_VIDEOS+=(0)
        CH_STATUS+=("up-to-date")

    elif [ $DOWNLOAD_EXIT_CODE -ne 0 ] && [ $DOWNLOAD_EXIT_CODE -ne 101 ]; then
        log "   ❌ Download failed after $((ELAPSED_TIME/60))m$((ELAPSED_TIME%60))s (exit: $DOWNLOAD_EXIT_CODE)"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        ARCHIVE_LINES_AFTER=$(wc -l < "$ARCHIVE_FILE" 2>/dev/null || echo 0)
        CH_VIDEOS+=($((ARCHIVE_LINES_AFTER - ARCHIVE_LINES_BEFORE)))
        CH_STATUS+=("FAILED (exit $DOWNLOAD_EXIT_CODE)")

        if [ "$SKIP_FAILED" = "false" ]; then
            log "   ⚠️  Stopping due to failure (skip_failed_channels=false)"
            CH_NAMES+=("$CHANNEL_NAME")
            CH_ELAPSED+=($ELAPSED_TIME)
            CH_SIZE+=("$SIZE_LABEL")
            CH_STALLS+=($CHANNEL_STALL_COUNT)
            break
        fi
    else
        ARCHIVE_LINES_AFTER=$(wc -l < "$ARCHIVE_FILE" 2>/dev/null || echo 0)
        NEW_VIDEOS=$((ARCHIVE_LINES_AFTER - ARCHIVE_LINES_BEFORE))

        if [ "$NEW_VIDEOS" -gt 0 ]; then
            log "   ✅ Downloaded $NEW_VIDEOS new video(s) | $SIZE_LABEL | $((ELAPSED_TIME/60))m$((ELAPSED_TIME%60))s"
            [ $CHANNEL_STALL_COUNT -gt 0 ] && log "   ⚠️  Recovered from $CHANNEL_STALL_COUNT rate-limit stall(s)"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            TOTAL_NEW_VIDEOS=$((TOTAL_NEW_VIDEOS + NEW_VIDEOS))
            CH_STATUS+=("ok")
            if command -v notify-send >/dev/null 2>&1; then
                notify-send -i face-surprise \
                    "🎉 $NEW_VIDEOS New Videos" \
                    "Downloaded for $CHANNEL_NAME in $((ELAPSED_TIME/60))m$((ELAPSED_TIME%60))s"
            fi
        else
            log "   ℹ️  No new videos downloaded ($((ELAPSED_TIME/60))m$((ELAPSED_TIME%60))s)"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            CH_STATUS+=("no new videos")
        fi
        CH_VIDEOS+=($NEW_VIDEOS)
    fi

    CH_NAMES+=("$CHANNEL_NAME")
    CH_ELAPSED+=($ELAPSED_TIME)
    CH_SIZE+=("$SIZE_LABEL")
    CH_STALLS+=($CHANNEL_STALL_COUNT)

    if [ $i -lt $((CHANNEL_COUNT - 1)) ]; then
        log "   ⏳ Waiting ${DELAY}s before next channel..."
        sleep "$DELAY"
    fi
done

RUN_END=$(date +%s)
RUN_ELAPSED=$((RUN_END - RUN_START))

# ---- Final summary ----
logn ""
logn "╔══════════════════════════════════════════════════════════════════════╗"
logn "║                    📊  DOWNLOAD RUN SUMMARY                        ║"
logn "╠══════════════════════════════════════════════════════════════════════╣"
logn "║  Started : $RUN_TIMESTAMP                          ║"
logn "║  Finished: $(date '+%Y-%m-%d %H:%M:%S')                          ║"
logn "║  Duration: $((RUN_ELAPSED/60))m $((RUN_ELAPSED%60))s                                              ║"
logn "╠══════════════════════════════════════════════════════════════════════╣"
printf "  %-28s %7s %10s %9s %7s\n" "Channel" "Videos" "Downloaded" "Time" "Stalls"
logn "  ──────────────────────────────────────────────────────────────────"
for ((j=0; j<${#CH_NAMES[@]}; j++)); do
    ch_m=$(( CH_ELAPSED[j] / 60 ))
    ch_s=$(( CH_ELAPSED[j] % 60 ))
    stall_col="${CH_STALLS[j]}"
    [ "${CH_STALLS[j]}" -gt 0 ] && stall_col="⚠️  ${CH_STALLS[j]}"
    printf "  %-28s %7s %10s  %4dm%02ds %7s  └─ %s\n" \
        "${CH_NAMES[j]:0:28}" \
        "${CH_VIDEOS[j]}" \
        "${CH_SIZE[j]}" \
        "$ch_m" "$ch_s" \
        "$stall_col" \
        "${CH_STATUS[j]}"
done
logn "  ──────────────────────────────────────────────────────────────────"
logn "  ✅  Processed  : $SUCCESS_COUNT channel(s)"
logn "  ❌  Failed     : $FAILED_COUNT channel(s)"
logn "  ⏭️   Skipped    : $SKIPPED_COUNT channel(s)"
logn "  🎥  New videos : $TOTAL_NEW_VIDEOS"
logn "  🛑  Rate limits: $RATE_LIMIT_EVENTS stall event(s)"
logn "  📁  Saved in   : $ROOT_DIR"
logn "╚══════════════════════════════════════════════════════════════════════╝"

if command -v notify-send >/dev/null 2>&1; then
    if [ $FAILED_COUNT -eq 0 ] && [ $TOTAL_NEW_VIDEOS -gt 0 ]; then
        notify-send -i face-smile \
            "✅ YouTube Download Complete" \
            "Downloaded $TOTAL_NEW_VIDEOS new videos"
    elif [ $FAILED_COUNT -eq 0 ]; then
        notify-send -i face-smile \
            "✅ YouTube Download Complete" \
            "No new videos found"
    else
        notify-send -i dialog-warning \
            "⚠️ YouTube Download Issues" \
            "$FAILED_COUNT channel(s) failed | $RATE_LIMIT_EVENTS rate-limit event(s)"
    fi
fi