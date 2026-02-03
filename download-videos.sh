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

YT_DLP=$(command -v yt-dlp)
JQ=$(command -v jq)

# ---- Dependency checks ----
for cmd in yt-dlp jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Dependency missing: $cmd"
        exit 1
    fi
done

[ ! -f "$CONFIG_FILE" ] && echo "❌ Config file not found: $CONFIG_FILE" && exit 1

echo "📋 Loading configuration from: $CONFIG_FILE"

# ---- Read configuration from the config file ----
ROOT_DIR=$(jq -r '.root_directory // "/media/monoar2/VIDEO REPO/services/media"' "$CONFIG_FILE")
DELAY=$(jq -r '.delay // 2' "$CONFIG_FILE")  # Reduced delay
CREATE_NFO_FILES=$(jq -r '.create_nfo_files // false' "$CONFIG_FILE")
FORCE_CODEC_COMPATIBILITY=$(jq -r '.force_codec_compatibility // false' "$CONFIG_FILE")
MAX_VIDEOS_PER_CHANNEL=$(jq -r '.max_videos_per_channel // 50' "$CONFIG_FILE")
DOWNLOAD_SUBTITLES=$(jq -r '.download_subtitles // false' "$CONFIG_FILE")  # Disabled for speed
VIDEO_QUALITY=$(jq -r '.video_quality // "best[height<=720]"' "$CONFIG_FILE")
SKIP_FAILED=$(jq -r '.skip_failed_channels // true' "$CONFIG_FILE")
OUTPUT_TEMPLATE=$(jq -r '.output_template // "Season 01/%(upload_date)s - %(title)s [%(id)s].%(ext)s"' "$CONFIG_FILE")
USE_COOKIES=$(jq -r '.use_cookies // true' "$CONFIG_FILE")  # Enabled for speed
COOKIES_FILE=$(jq -r '.cookies_file // "cookies.txt"' "$CONFIG_FILE")

# ---- Fix cookie file path ----
if [ "$USE_COOKIES" = "true" ]; then
    CONFIG_DIR=$(dirname "$CONFIG_FILE")
    if [[ "$COOKIES_FILE" != /* ]]; then
        COOKIES_FILE="$CONFIG_DIR/$COOKIES_FILE"
    fi
fi

echo "📁 Root directory: $ROOT_DIR"
echo "⏱️  Delay between channels: ${DELAY}s"
echo "🎬 Max videos per channel: $MAX_VIDEOS_PER_CHANNEL"
echo "📺 Video quality: $VIDEO_QUALITY"
echo "🔄 Skip failed channels: $SKIP_FAILED"
echo "🍪 Use cookies: $USE_COOKIES"
echo "⚡ OPTIMIZED FOR SPEED"

# Check if cookies file exists
if [ "$USE_COOKIES" = "true" ]; then
    if [ -f "$COOKIES_FILE" ]; then
        echo "✅ Cookies file found: $COOKIES_FILE"
    else
        echo "❌ Cookies file not found: $COOKIES_FILE"
        echo "   Downloading without cookies (may be slower)"
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
echo "🔄 Updating yt-dlp to nightly build (for better speed)..."
$YT_DLP --update-to nightly --no-warnings 2>/dev/null || echo "⚠️ yt-dlp update may have failed, continuing..."

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

for ((i=0; i<CHANNEL_COUNT; i++)); do
    echo ""
    CHANNEL_URL=$(jq -r ".channels[$i].url" "$CONFIG_FILE")
    CHANNEL_NAME_OVERRIDE=$(jq -r ".channels[$i].name // empty" "$CONFIG_FILE")
    FETCH_ONLY_NEW=$(jq -r ".channels[$i].fetch_only_new // false" "$CONFIG_FILE")
    CHANNEL_MAX_VIDEOS=$(jq -r ".channels[$i].max_videos // $MAX_VIDEOS_PER_CHANNEL" "$CONFIG_FILE")
    CHANNEL_ENABLED=$(jq -r ".channels[$i].enabled // true" "$CONFIG_FILE")
    
    # Skip disabled channels
    if [ "$CHANNEL_ENABLED" = "false" ]; then
        echo "⏭️  Skipping disabled channel: $CHANNEL_NAME_OVERRIDE"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
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
    
    echo "🎬 Processing: $CHANNEL_NAME"
    echo "   📍 URL: $CHANNEL_URL"
    
    # Track archive size BEFORE download
    ARCHIVE_LINES_BEFORE=0
    if [ -f "$ARCHIVE_FILE" ]; then
        ARCHIVE_LINES_BEFORE=$(wc -l < "$ARCHIVE_FILE" 2>/dev/null || echo 0)
        echo "   📊 Previously downloaded: $ARCHIVE_LINES_BEFORE videos"
    fi
    
    # Create Season 01 directory for downloads
    mkdir -p "$CHANNEL_DIR/Season 01"
    
    # Fetch-only-new logic
    if [ "$FETCH_ONLY_NEW" = "true" ] && [ -f "$ARCHIVE_FILE" ] && [ -s "$ARCHIVE_FILE" ]; then
        echo "   🔄 Mode: Fetch-only-new (skip already downloaded)"
        BREAK_FLAG="--break-on-existing"
    else
        echo "   📦 Mode: Initial download (max $CHANNEL_MAX_VIDEOS videos)"
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
        --concurrent-fragments 5  # INCREASED for parallel downloading
        --fragment-retries 10
        --retries 10
        --retry-sleep fragment:2
        --sleep-interval 5  # REDUCED sleep time
        --max-sleep-interval 30
        --throttled-rate 1M
        --write-info-json
        --write-description
        --write-thumbnail
        --embed-thumbnail
        --embed-metadata
        --add-metadata
        --parse-metadata "%(upload_date)s:%(meta_date)s"
        --output "$OUTPUT_TEMPLATE"
        $BREAK_FLAG
        --playlist-end "$CHANNEL_MAX_VIDEOS"
        --extractor-args "youtube:player_client=android,web"
        --throttled-rate 1M
        --limit-rate 10M  # INCREASED speed limit
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
    
    # Add cookies if enabled (CRITICAL for speed)
    if [ "$USE_COOKIES" = "true" ]; then
        YT_DLP_ARGS+=(--cookies "$COOKIES_FILE")
        echo "   🍪 Using cookies (important for speed)"
    else
        echo "   ⚠️  No cookies - downloads may be slower"
    fi
    
    # Add subtitle options if enabled (disabled by default for speed)
    if [ "$DOWNLOAD_SUBTITLES" = "true" ]; then
        YT_DLP_ARGS+=(--write-subs --sub-langs "en" --convert-subs srt --embed-subs)
        echo "   📝 Downloading subtitles (slower)"
    fi
    
    # Add codec compatibility if forced
    if [ "$FORCE_CODEC_COMPATIBILITY" = "true" ]; then
        YT_DLP_ARGS+=(--recode-video mp4 --audio-codec aac --video-codec h264)
        echo "   🔄 Forcing codec compatibility (slower)"
    fi
    
    # Add the channel URL
    YT_DLP_ARGS+=("$CHANNEL_URL")
    
    # ---- Execute yt-dlp command ----
    cd "$CHANNEL_DIR" || {
        echo "❌ Failed to change to channel directory: $CHANNEL_DIR"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    }
    
    echo "   ⚡ Starting FAST download..."
    
    # Start timer
    START_TIME=$(date +%s)
    
    # Execute yt-dlp
    if $YT_DLP "${YT_DLP_ARGS[@]}"; then
        DOWNLOAD_EXIT_CODE=0
    else
        DOWNLOAD_EXIT_CODE=$?
    fi
    
    # Calculate elapsed time
    END_TIME=$(date +%s)
    ELAPSED_TIME=$((END_TIME - START_TIME))
    
    # Return to root directory
    cd "$ROOT_DIR" || {
        echo "⚠️ Warning: Could not return to root directory"
    }
    
    # ---- Post-download handling ----
    if [ $DOWNLOAD_EXIT_CODE -eq 101 ]; then
        echo "   ⚠️  No new videos found (already downloaded)"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        
    elif [ $DOWNLOAD_EXIT_CODE -ne 0 ] && [ $DOWNLOAD_EXIT_CODE -ne 101 ]; then
        echo "   ❌ Download failed after ${ELAPSED_TIME}s (exit code: $DOWNLOAD_EXIT_CODE)"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        
        if [ "$SKIP_FAILED" = "false" ]; then
            echo "   ⚠️  Stopping due to failure"
            break
        fi
    else
        # Check for new videos
        ARCHIVE_LINES_AFTER=$(wc -l < "$ARCHIVE_FILE" 2>/dev/null || echo 0)
        if [ "$ARCHIVE_LINES_AFTER" -gt "$ARCHIVE_LINES_BEFORE" ]; then
            NEW_VIDEOS=$((ARCHIVE_LINES_AFTER - ARCHIVE_LINES_BEFORE))
            echo "   ✅ Success! Downloaded $NEW_VIDEOS new video(s) in ${ELAPSED_TIME}s"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            TOTAL_NEW_VIDEOS=$((TOTAL_NEW_VIDEOS + NEW_VIDEOS))
            
            if command -v notify-send >/dev/null 2>&1; then
                notify-send -i face-surprise \
                    "🎉 $NEW_VIDEOS New Videos" \
                    "Downloaded for $CHANNEL_NAME in ${ELAPSED_TIME}s"
            fi
        else
            echo "   ℹ️  No new videos downloaded (took ${ELAPSED_TIME}s)"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        fi
    fi
    
    # Short delay between channels
    if [ $i -lt $((CHANNEL_COUNT - 1)) ]; then
        echo "   ⏳ Waiting ${DELAY}s before next channel..."
        sleep "$DELAY"
    fi
    echo "   ----------------------------------------"
done

echo ""
echo "========================================"
echo "📊 Download Summary:"
echo "   ✅ Successfully processed: $SUCCESS_COUNT channel(s)"
echo "   ❌ Failed: $FAILED_COUNT channel(s)"
echo "   ⏭️  Skipped: $SKIPPED_COUNT channel(s)"
echo "   🎥 Total new videos: $TOTAL_NEW_VIDEOS"
echo ""
echo "📺 All videos saved in: $ROOT_DIR"

# Send final notification
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
            "$FAILED_COUNT channels failed"
    fi
fi