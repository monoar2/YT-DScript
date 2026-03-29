#!/bin/bash
# ytdl-monitor.sh - Live download monitoring dashboard for tty3
# Switch to this console with: Alt+F3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config.json}"
MEDIA_DIR=$(jq -r '.root_directory // "/media/youtube"' "$CONFIG_FILE" 2>/dev/null || echo "/media/youtube")
LOG_FILE="$SCRIPT_DIR/download.log"
REFRESH=5

while true; do
    clear
    COLS=$(tput cols 2>/dev/null || echo 70)
    LINE=$(printf '═%.0s' $(seq 1 $COLS))
    THIN=$(printf '─%.0s' $(seq 1 $COLS))

    echo "$LINE"
    printf " 📺  YT-DScript Monitor  │  $(date '+%Y-%m-%d %H:%M:%S')  │  Refresh: ${REFRESH}s\n"
    echo "$LINE"

    # ── Active yt-dlp processes ──────────────────────────────────────────
    echo ""
    echo "  ⚙️  ACTIVE PROCESSES"
    echo "  $THIN"
    YT_PIDS=$(pgrep -x yt-dlp 2>/dev/null)
    if [ -n "$YT_PIDS" ]; then
        ps -o pid,pcpu,pmem,etime,args -p $YT_PIDS 2>/dev/null \
            | tail -n +2 \
            | while read -r line; do echo "  $line"; done
    else
        echo "  (no yt-dlp process running)"
    fi

    # ── Current partial downloads (.part files) ──────────────────────────
    PARTS=$(find "$MEDIA_DIR" -name "*.part" 2>/dev/null)
    if [ -n "$PARTS" ]; then
        echo ""
        echo "  ⬇️  IN PROGRESS"
        echo "  $THIN"
        echo "$PARTS" | while read -r f; do
            size=$(du -sh "$f" 2>/dev/null | cut -f1)
            printf "  %-12s  %s\n" "$size" "$(basename "$f")"
        done
    fi

    # ── Media directory sizes ─────────────────────────────────────────────
    echo ""
    echo "  💾  MEDIA SIZES"
    echo "  $THIN"
    if [ -d "$MEDIA_DIR" ]; then
        du -sh "$MEDIA_DIR"/*/  2>/dev/null \
            | sort -rh \
            | head -15 \
            | while read -r size path; do
                printf "  %-10s  %s\n" "$size" "$(basename "$path")"
              done
        echo "  $THIN"
        TOTAL=$(du -sh "$MEDIA_DIR" 2>/dev/null | cut -f1)
        DISK=$(df -h "$MEDIA_DIR" 2>/dev/null | tail -1 | awk '{printf "%s used / %s total (%s)", $3, $2, $5}')
        printf "  Total media : %-10s\n" "$TOTAL"
        printf "  Drive usage : %s\n"    "$DISK"
    else
        echo "  (media dir not mounted)"
    fi

    # ── Last log entries ──────────────────────────────────────────────────
    echo ""
    echo "  📋  RECENT LOG  ($LOG_FILE)"
    echo "  $THIN"
    if [ -f "$LOG_FILE" ]; then
        # Calculate available lines: terminal height minus ~25 lines for header
        AVAILABLE=$(( $(tput lines 2>/dev/null || echo 40) - 28 ))
        [ $AVAILABLE -lt 5 ] && AVAILABLE=5
        tail -n $AVAILABLE "$LOG_FILE" | while read -r line; do echo "  $line"; done
    else
        echo "  (no log file yet — waiting for first cron run)"
        echo "  Run manually: bash $SCRIPT_DIR/download-videos.sh"
    fi

    echo ""
    printf "  %s\n" "$THIN"
    printf "  Ctrl+C to exit monitor  │  Alt+F1/F2 to switch console\n"

    sleep $REFRESH
done
