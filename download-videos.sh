#!/bin/bash

# Usage:
# ./download_channel_videos.sh config.json

# ---- Desktop notifications (cron-safe) ----
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
export DISPLAY=":0"

CONFIG_FILE="$1"
YT_DLP=$(command -v yt-dlp)
JQ=$(command -v jq)

# ---- Dependency checks ----
for cmd in "$YT_DLP" "$JQ"; do
    [ -z "$cmd" ] && echo "❌ Dependency missing: $cmd" && exit 1
done

[ -z "$CONFIG_FILE" ] && echo "❌ No configuration file provided." && exit 1
[ ! -f "$CONFIG_FILE" ] && echo "❌ Config file not found: $CONFIG_FILE" && exit 1

# ---- Update yt-dlp (nightly = fastest YouTube fixes) ----
echo "🔄 Updating yt-dlp..."
$YT_DLP --update-to nightly --no-warnings || echo "⚠️ yt-dlp update failed, continuing..."

DELAY=$(jq -r '.delay // 5' "$CONFIG_FILE")
CHANNEL_COUNT=$(jq '.channels | length' "$CONFIG_FILE")

for ((i=0; i<CHANNEL_COUNT; i++)); do
    CHANNEL_URL=$(jq -r ".channels[$i].url" "$CONFIG_FILE")
    FETCH_ONLY_NEW=$(jq -r ".channels[$i].fetch_only_new // false" "$CONFIG_FILE")

    # Ensure /videos tab
    [[ ! "$CHANNEL_URL" =~ /videos$ ]] && CHANNEL_URL="${CHANNEL_URL}/videos"

    CHANNEL_NAME=$(basename "$(dirname "$CHANNEL_URL")")
    mkdir -p "$CHANNEL_NAME"
    ARCHIVE_FILE="$CHANNEL_NAME/downloaded.txt"

    echo "⬇️  Downloading videos for $CHANNEL_NAME..."

    # Track archive size BEFORE download (FIXED)
    ARCHIVE_LINES_BEFORE=$(wc -l < "$ARCHIVE_FILE" 2>/dev/null || echo 0)

    # Fetch-only-new logic
    if [ "$FETCH_ONLY_NEW" = "true" ] && [ -s "$ARCHIVE_FILE" ]; then
        echo "📌 Fetch-only-new mode enabled"
        BREAK_FLAG="--break-on-existing"
    else
        echo "📦 Initial download mode (latest 100 videos)"
        BREAK_FLAG=""
    fi

    # ---- yt-dlp command (HARDENED) ----
    $YT_DLP \
        --ignore-errors \
        --no-warnings \
        --match-filter "duration >= 600" \
        --playlist-end 100 \
        $BREAK_FLAG \
        --sleep-requests 1 \
        --sleep-interval 5 \
        --max-sleep-interval 15 \
        -N 1 \
        --limit-rate 5M \
        --merge-output-format mp4 \
        --output "$CHANNEL_NAME/%(upload_date)s - %(title)s [%(id)s].%(ext)s" \
        --download-archive "$ARCHIVE_FILE" \
        --no-overwrites \
        -f "bv*[vcodec^=avc][height<=720]+ba[acodec^=mp4a]/b" \
        --retries infinite \
        --retry-sleep 30 \
        --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36" \
        "$CHANNEL_URL"

    DOWNLOAD_EXIT_CODE=$?

    # ---- Post-download handling ----
    if [ $DOWNLOAD_EXIT_CODE -eq 101 ]; then
        echo "⚠️ yt-dlp exited with 101 (expected when breaking on existing videos)"
        echo "✅ No new videos for $CHANNEL_NAME"

    elif [ $DOWNLOAD_EXIT_CODE -ne 0 ]; then
        notify-send -i dialog-error \
            "❌ Download Failed for $CHANNEL_NAME" \
            "yt-dlp exited with code $DOWNLOAD_EXIT_CODE"
        echo "❌ Download failed for $CHANNEL_NAME (code $DOWNLOAD_EXIT_CODE)"

    else
        ARCHIVE_LINES_AFTER=$(wc -l < "$ARCHIVE_FILE" 2>/dev/null || echo 0)
        if [ "$ARCHIVE_LINES_AFTER" -gt "$ARCHIVE_LINES_BEFORE" ]; then
            NEW_VIDEOS=$((ARCHIVE_LINES_AFTER - ARCHIVE_LINES_BEFORE))
            notify-send -i face-surprise \
                "🎉 $NEW_VIDEOS New Videos" \
                "Downloaded for $CHANNEL_NAME"
            echo "🎉 $NEW_VIDEOS new videos downloaded for $CHANNEL_NAME"
        else
            echo "✅ No new videos for $CHANNEL_NAME"
        fi
    fi

    # ---- VLC playlist generation ----
    if compgen -G "$CHANNEL_NAME/*.mp4" > /dev/null; then
        PLAYLIST="$CHANNEL_NAME/playlist.xspf"
        {
            echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            echo "<playlist version=\"1\" xmlns=\"http://xspf.org/ns/0/\">"
            echo "  <trackList>"
            for VIDEO in "$CHANNEL_NAME"/*.mp4; do
                printf "    <track>\n      <location>file://%s</location>\n      <title>%s</title>\n    </track>\n" \
                    "$(realpath "$VIDEO")" "$(basename "$VIDEO")"
            done
            echo "  </trackList>"
            echo "</playlist>"
        } > "$PLAYLIST"
        echo "🎵 VLC playlist generated: $PLAYLIST"
    fi

    [ $i -lt $((CHANNEL_COUNT - 1)) ] && echo "⏳ Waiting $DELAY seconds..." && sleep "$DELAY"
    echo "----------------------------------------"
done

echo "✅ All done!"

