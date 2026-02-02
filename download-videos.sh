#!/bin/bash

# YouTube Channel Downloader for Jellyfin
# Downloads YouTube channels and organizes them for Jellyfin TV show library

# ---- Desktop notifications (cron-safe) ----
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
export DISPLAY=":0"

# ---- Determine config file path ----
if [ -n "$1" ]; then
    CONFIG_FILE="$1"
else
    # Look for config.json in the script directory
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
DELAY=$(jq -r '.delay // 5' "$CONFIG_FILE")
CREATE_NFO_FILES=$(jq -r '.create_nfo_files // false' "$CONFIG_FILE")
FORCE_CODEC_COMPATIBILITY=$(jq -r '.force_codec_compatibility // false' "$CONFIG_FILE")
MAX_VIDEOS_PER_CHANNEL=$(jq -r '.max_videos_per_channel // 100' "$CONFIG_FILE")
DOWNLOAD_SUBTITLES=$(jq -r '.download_subtitles // true' "$CONFIG_FILE")
VIDEO_QUALITY=$(jq -r '.video_quality // "best[height<=720]"' "$CONFIG_FILE")
SKIP_FAILED=$(jq -r '.skip_failed_channels // true' "$CONFIG_FILE")
OUTPUT_TEMPLATE=$(jq -r '.output_template // "Season 01/%(upload_date)s - %(title)s [%(id)s].%(ext)s"' "$CONFIG_FILE")
USE_COOKIES=$(jq -r '.use_cookies // false' "$CONFIG_FILE")
COOKIES_FILE=$(jq -r '.cookies_file // "cookies.txt"' "$CONFIG_FILE")

# ---- Fix cookie file path ----
# If cookies_file is relative, make it absolute relative to config file location
if [ "$USE_COOKIES" = "true" ]; then
    CONFIG_DIR=$(dirname "$CONFIG_FILE")
    if [[ "$COOKIES_FILE" != /* ]]; then
        # It's a relative path, make it absolute relative to config directory
        COOKIES_FILE="$CONFIG_DIR/$COOKIES_FILE"
    fi
fi

echo "📁 Root directory: $ROOT_DIR"
echo "⏱️  Delay between channels: ${DELAY}s"
echo "📝 Create NFO files: $CREATE_NFO_FILES"
echo "🎬 Max videos per channel: $MAX_VIDEOS_PER_CHANNEL"
echo "📺 Video quality: $VIDEO_QUALITY"
echo "🔄 Skip failed channels: $SKIP_FAILED"
echo "🍪 Use cookies: $USE_COOKIES"

# Check if cookies file exists
if [ "$USE_COOKIES" = "true" ]; then
    if [ -f "$COOKIES_FILE" ]; then
        echo "✅ Cookies file found: $COOKIES_FILE"
        COOKIES_SIZE=$(wc -c < "$COOKIES_FILE")
        echo "   📏 Cookies file size: $COOKIES_SIZE bytes"
        
        # Check if cookies file has valid content
        if grep -q "youtube.com" "$COOKIES_FILE"; then
            echo "   ✓ Cookies file contains YouTube cookies"
        else
            echo "   ⚠️  Cookies file doesn't appear to contain YouTube cookies"
        fi
    else
        echo "❌ Cookies enabled but file not found: $COOKIES_FILE"
        echo "   Looking in:"
        echo "   - $COOKIES_FILE"
        echo "   - $(pwd)/cookies.txt"
        echo "   - $CONFIG_DIR/cookies.txt"
        echo "   Will continue without cookies..."
        USE_COOKIES="false"
    fi
fi

# Create root directory if it doesn't exist
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR" || {
    echo "❌ Failed to change to root directory: $ROOT_DIR"
    exit 1
}

# ---- Update yt-dlp (skip if installed via apt) ----
if ! dpkg -l | grep -q yt-dlp; then
    echo "🔄 Updating yt-dlp to nightly build..."
    $YT_DLP --update-to nightly --no-warnings 2>/dev/null || echo "⚠️ yt-dlp update skipped (apt install detected)"
else
    echo "ℹ️  yt-dlp installed via apt, skipping auto-update"
fi

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
        # ==== FIXED: Keep @ symbol for compatibility with existing folders ====
        # Fixed sed command: - needs to be escaped or placed at start/end of character class
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
    
    # ---- Build yt-dlp command with YouTube workarounds ----
    YT_DLP_ARGS=(
        --yes-playlist
        --ignore-errors
        --continue
        --no-overwrites
        --download-archive "downloaded.txt"
        --format "$VIDEO_QUALITY"
        --merge-output-format mp4
        --remux-video mp4
        --concurrent-fragments 1
        --fragment-retries 5
        --retries 3
        --retry-sleep fragment:exp=1.5:20
        --sleep-interval 60
        --max-sleep-interval 180
        --throttled-rate 50K
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
        --throttled-rate 50K
        --limit-rate 500K
        --force-ipv4
        --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    )
    
    # Add cookies if enabled
    if [ "$USE_COOKIES" = "true" ]; then
        YT_DLP_ARGS+=(--cookies "$COOKIES_FILE")
        echo "   🍪 Using cookies file: $COOKIES_FILE"
    else
        echo "   ⚠️  Downloading without cookies"
    fi
    
    # Add subtitle options if enabled
    if [ "$DOWNLOAD_SUBTITLES" = "true" ]; then
        YT_DLP_ARGS+=(--write-subs --sub-langs "en,all,-live_chat" --convert-subs srt --embed-subs)
    fi
    
    # Add codec compatibility if forced
    if [ "$FORCE_CODEC_COMPATIBILITY" = "true" ]; then
        YT_DLP_ARGS+=(--recode-video mp4 --audio-codec aac --video-codec h264)
    fi
    
    # Add the channel URL
    YT_DLP_ARGS+=("$CHANNEL_URL")
    
    # ---- Execute yt-dlp command ----
    cd "$CHANNEL_DIR" || {
        echo "❌ Failed to change to channel directory: $CHANNEL_DIR"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    }
    
    echo "   ⚙️  Starting download..."
    echo "   ⚠️  This may take a while (YouTube rate limits)..."
    
    # Execute yt-dlp with timeout and retry logic
    MAX_RETRIES=1  # Only 1 retry to avoid hitting rate limits
    RETRY_COUNT=0
    DOWNLOAD_SUCCESS=false
    DOWNLOAD_EXIT_CODE=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$DOWNLOAD_SUCCESS" = false ]; do
        if [ $RETRY_COUNT -gt 0 ]; then
            echo "   🔄 Retry attempt $RETRY_COUNT of $MAX_RETRIES..."
            sleep 120  # Wait 2 minutes between retries
        fi
        
        if $YT_DLP "${YT_DLP_ARGS[@]}"; then
            DOWNLOAD_SUCCESS=true
            DOWNLOAD_EXIT_CODE=0
        else
            DOWNLOAD_EXIT_CODE=$?
            RETRY_COUNT=$((RETRY_COUNT + 1))
            
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                echo "   ⚠️  Download failed, will retry in 120 seconds..."
            fi
        fi
    done
    
    # Return to root directory
    cd "$ROOT_DIR" || {
        echo "⚠️ Warning: Could not return to root directory"
    }
    
    # ---- Post-download handling ----
    if [ $DOWNLOAD_EXIT_CODE -eq 101 ]; then
        echo "   ⚠️  No new videos found (already downloaded)"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        
    elif [ $DOWNLOAD_EXIT_CODE -ne 0 ] && [ $DOWNLOAD_EXIT_CODE -ne 101 ]; then
        echo "   ❌ Download failed after $MAX_RETRIES attempts (exit code: $DOWNLOAD_EXIT_CODE)"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        
        if [ "$SKIP_FAILED" = "false" ]; then
            echo "   ⚠️  Stopping due to failure (skip_failed_channels is false)"
            break
        fi
        
        if command -v notify-send >/dev/null 2>&1; then
            notify-send -i dialog-error \
                "❌ Download Failed" \
                "Failed to download: $CHANNEL_NAME after $MAX_RETRIES attempts"
        fi
    else
        # Check for new videos
        ARCHIVE_LINES_AFTER=$(wc -l < "$ARCHIVE_FILE" 2>/dev/null || echo 0)
        if [ "$ARCHIVE_LINES_AFTER" -gt "$ARCHIVE_LINES_BEFORE" ]; then
            NEW_VIDEOS=$((ARCHIVE_LINES_AFTER - ARCHIVE_LINES_BEFORE))
            echo "   ✅ Success! Downloaded $NEW_VIDEOS new video(s)"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            TOTAL_NEW_VIDEOS=$((TOTAL_NEW_VIDEOS + NEW_VIDEOS))
            
            if command -v notify-send >/dev/null 2>&1; then
                notify-send -i face-surprise \
                    "🎉 $NEW_VIDEOS New Videos" \
                    "Downloaded for $CHANNEL_NAME"
            fi
        else
            echo "   ℹ️  No new videos downloaded"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))  # Still counts as success if nothing new
        fi
        
        # ---- Create Jellyfin metadata files ----
        if [ -d "$CHANNEL_DIR/Season 01" ] && [ "$(ls -A "$CHANNEL_DIR/Season 01" 2>/dev/null)" ]; then
            echo "   📊 Creating Jellyfin metadata..."
            
            # Create show-level NFO
            cat > "$CHANNEL_DIR/tvshow.nfo" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<tvshow>
    <title>$CHANNEL_NAME</title>
    <plot>YouTube channel: $CHANNEL_NAME</plot>
    <genre>YouTube</genre>
    <studio>YouTube</studio>
    <premiered>$(date +%Y-%m-%d)</premiered>
</tvshow>
EOF
            
            # Create episode NFO files if enabled
            if [ "$CREATE_NFO_FILES" = "true" ]; then
                echo "   📝 Creating NFO files..."
                find "$CHANNEL_DIR/Season 01" -name "*.info.json" | while read -r JSON_FILE; do
                    VIDEO_ID=$(basename "$JSON_FILE" .info.json | sed 's/.*\[\(.*\)\]/\1/')
                    VIDEO_TITLE=$(jq -r '.title' "$JSON_FILE" 2>/dev/null || echo "$VIDEO_ID")
                    VIDEO_DESC=$(jq -r '.description // ""' "$JSON_FILE" 2>/dev/null | head -c 500)
                    UPLOAD_DATE=$(jq -r '.upload_date // ""' "$JSON_FILE" 2>/dev/null)
                    UPLOAD_DATE_FORMATTED=$(echo "$UPLOAD_DATE" | sed 's/\(....\)\(..\)\(..\)/\1-\2-\3/')
                    
                    # Find the corresponding video file
                    VIDEO_FILE=$(find "$CHANNEL_DIR/Season 01" -name "*[$VIDEO_ID]*" -not -name "*.json" -not -name "*.description" -not -name "*.jpg" -not -name "*.webp" -not -name "*.srt" | head -1)
                    if [ -n "$VIDEO_FILE" ]; then
                        NFO_FILE="${VIDEO_FILE%.*}.nfo"
                        cat > "$NFO_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<episodedetails>
    <title>$(echo "$VIDEO_TITLE" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</title>
    <showtitle>$CHANNEL_NAME</showtitle>
    <season>1</season>
    <episode>${UPLOAD_DATE:-00000000}</episode>
    <plot>$(echo "$VIDEO_DESC" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</plot>
    <premiered>$UPLOAD_DATE_FORMATTED</premiered>
    <studio>YouTube</studio>
    <uniqueid type="youtube" default="true">$VIDEO_ID</uniqueid>
</episodedetails>
EOF
                    fi
                done
            fi
            
            echo "   🎬 Jellyfin metadata created"
        fi
    fi
    
    # Delay between channels (except for the last one)
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
echo "🔧 Remember to refresh your Jellyfin library to see new content!"
echo ""

# Send final notification
if command -v notify-send >/dev/null 2>&1; then
    if [ $FAILED_COUNT -eq 0 ] && [ $TOTAL_NEW_VIDEOS -gt 0 ]; then
        notify-send -i face-smile \
            "✅ YouTube Download Complete" \
            "Downloaded $TOTAL_NEW_VIDEOS new videos from $SUCCESS_COUNT channels"
    elif [ $FAILED_COUNT -eq 0 ]; then
        notify-send -i face-smile \
            "✅ YouTube Download Complete" \
            "No new videos found. Processed $SUCCESS_COUNT channels"
    else
        notify-send -i dialog-warning \
            "⚠️ YouTube Download Complete with Errors" \
            "$SUCCESS_COUNT succeeded, $FAILED_COUNT failed, $TOTAL_NEW_VIDEOS new videos"
    fi
fi