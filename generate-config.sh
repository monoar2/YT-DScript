#!/bin/bash
# generate-config.sh
# Generates or updates config.json from a Google Takeout subscriptions CSV.
#
# HOW TO EXPORT YOUR SUBSCRIPTIONS:
#   1. Go to https://takeout.google.com
#   2. Click "Deselect all", then find "YouTube and YouTube Music" → check it
#   3. Click "All YouTube data included" → uncheck everything except "subscriptions"
#   4. Export → download the zip → extract subscriptions.csv
#   5. Run: ./generate-config.sh /path/to/subscriptions.csv
#
# The CSV format is:
#   Channel Id,Channel Url,Channel Title
#   UCxxxxxxxx,http://www.youtube.com/channel/UCxxxxxxxx,Channel Name

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
CSV_FILE="${1:-}"

# ---- Helpers ----
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { echo "❌ $*" >&2; exit 1; }

# ---- Dependency check ----
command -v jq &>/dev/null || err "jq not found — install with: sudo apt install jq"

# ---- Validate CSV argument ----
if [ -z "$CSV_FILE" ]; then
    echo ""
    echo "Usage: $0 <subscriptions.csv> [config.json]"
    echo ""
    echo "  subscriptions.csv  — exported from Google Takeout"
    echo "  config.json        — output path (default: ./config.json)"
    echo ""
    echo "HOW TO EXPORT FROM GOOGLE TAKEOUT:"
    echo "  1. Go to https://takeout.google.com"
    echo "  2. Deselect all → select 'YouTube and YouTube Music'"
    echo "  3. Click 'All YouTube data included' → select only 'subscriptions'"
    echo "  4. Export → download zip → extract subscriptions.csv"
    echo ""
    exit 1
fi

# Allow config path override as second argument
[ -n "${2:-}" ] && CONFIG_FILE="$2"

[ -f "$CSV_FILE" ] || err "CSV file not found: $CSV_FILE"

# ---- Parse CSV ----
# Skip the header line (Channel Id,Channel Url,Channel Title)
# Fields: channel_id, channel_url, channel_title
log "📂 Parsing: $CSV_FILE"

CHANNELS_JSON=$(tail -n +2 "$CSV_FILE" | while IFS=',' read -r channel_id channel_url channel_title; do
    # Strip surrounding whitespace and quotes
    channel_id=$(echo "$channel_id"    | tr -d '"' | xargs)
    channel_url=$(echo "$channel_url"  | tr -d '"' | xargs)
    channel_title=$(echo "$channel_title" | tr -d '"' | xargs)

    [ -z "$channel_id" ] && continue

    # Normalize URL to https and prefer @handle if present, else use /channel/ID
    if [[ "$channel_url" =~ /@[a-zA-Z0-9_.-]+ ]]; then
        handle=$(echo "$channel_url" | grep -oP '/@[a-zA-Z0-9_.-]+')
        clean_url="https://www.youtube.com${handle}"
    else
        clean_url="https://www.youtube.com/channel/${channel_id}"
    fi

    # Sanitize title for use as a folder name (keep alphanumeric, dots, dashes, underscores)
    safe_name=$(echo "$channel_title" | sed 's/[^a-zA-Z0-9._-]//g' | cut -c1-60)
    [ -z "$safe_name" ] && safe_name="$channel_id"

    jq -n \
        --arg name "$safe_name" \
        --arg url  "$clean_url" \
        '{name: $name, url: $url, fetch_only_new: true, enabled: true}'
done | jq -s '.')

CHANNEL_COUNT=$(echo "$CHANNELS_JSON" | jq 'length')
[ "$CHANNEL_COUNT" -eq 0 ] && err "No channels parsed from CSV. Check the file format."
log "✅ Parsed $CHANNEL_COUNT subscriptions"

# ---- Merge or create config.json ----
if [ -f "$CONFIG_FILE" ]; then
    log "📋 Existing config.json found — merging channels..."

    PREV_COUNT=$(jq '.channels | length' "$CONFIG_FILE")
    log "   Previous channel count : $PREV_COUNT"
    log "   New channel count       : $CHANNEL_COUNT"

    # Preserve all settings, replace only the channels array
    jq --argjson channels "$CHANNELS_JSON" \
        '.channels = $channels' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
else
    log "📝 No existing config.json — creating with defaults..."
    jq -n \
        --argjson channels "$CHANNELS_JSON" \
        '{
            root_directory:            "/ext/mnt/MyTube/media",
            delay:                     5,
            max_videos_per_channel:    200,
            video_quality:             "best[height<=1080]",
            download_subtitles:        false,
            create_nfo_files:          false,
            force_codec_compatibility: false,
            skip_failed_channels:      true,
            use_cookies:               true,
            cookies_file:              "cookies.txt",
            output_template:           "Season 01/%(upload_date)s - %(title)s [%(id)s].%(ext)s",
            stall_timeout:             300,
            stall_retry_wait:          600,
            stall_max_retries:         3,
            channels:                  $channels
        }' > "$CONFIG_FILE"
fi

# ---- Summary ----
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "✅ Done! config.json updated: $CONFIG_FILE"
log "   Total channels: $(jq '.channels | length' "$CONFIG_FILE")"
echo ""
echo "First 5 channels:"
jq -r '.channels[:5][] | "   \(.name)  →  \(.url)"' "$CONFIG_FILE"
echo ""
echo "Next steps:"
echo "   1. Review config.json and disable channels you don't want:"
echo "        Set \"enabled\": false for any channel"
echo "   2. Run ./validate-channels.sh to check all URLs resolve"
echo "   3. Run ./download-videos.sh to start downloading"
echo ""
