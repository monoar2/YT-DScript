# YT-DScript — Copilot Context

## Project Overview
**YT-DScript** is a Bash-based automation system for downloading YouTube channel videos and serving them through a self-hosted [Jellyfin](https://jellyfin.org/) media server via Docker. It is designed for long-term archiving and unattended cron operation.

---

## Repository Structure

| File | Purpose |
|------|---------|
| `download-videos.sh` | Main download script — reads `config.json`, iterates channels, calls `yt-dlp` |
| `config.json` | Primary config: channel list, quality, paths, cookies, stall settings |
| `config.json (copy).template` | Template for creating a new `config.json` |
| `ytdl-monitor.sh` | Live terminal dashboard (designed for tty3 / `Alt+F3`) |
| `validate-channels.sh` | HTTP-checks all channel URLs in config; reports 200/404 per channel |
| `docker-compose.yml` | Jellyfin container definition — reads `.env` for paths/ports |
| `start-jellyfin.sh` | Validates `.env`, creates dirs, starts Jellyfin Docker container |
| `stop-jellyfin.sh` | Stops the Jellyfin Docker container |
| `update-jellyfin.sh` | Pulls latest Jellyfin image and restarts container |
| `backup-jellyfin.sh` | Stops Jellyfin, archives config+cache, restarts |
| `cookies.txt` | YouTube auth cookies used to avoid rate-limiting/403 errors |

---

## Configuration (`config.json`)

Key fields and their defaults:

```json
{
  "root_directory": "/ext/mnt/MyTube/media",   // where channel folders are created
  "delay": 5,                                   // seconds between channels
  "max_videos_per_channel": 200,                // global cap (overridable per channel)
  "video_quality": "best[height<=1080]",        // yt-dlp format selector
  "download_subtitles": false,
  "create_nfo_files": false,
  "force_codec_compatibility": false,           // forces MP4 remux via ffmpeg
  "skip_failed_channels": true,
  "use_cookies": true,
  "cookies_file": "cookies.txt",
  "output_template": "Season 01/%(upload_date)s - %(title)s [%(id)s].%(ext)s",
  "stall_timeout": 300,
  "stall_retry_wait": 600,
  "stall_max_retries": 3,
  "channels": [ ... ]
}
```

**Per-channel fields:**
- `name` — folder name created under `root_directory`
- `url` — YouTube channel URL (use `@handle` format, NOT `/videos`)
- `fetch_only_new` — only download videos not already present
- `enabled` — set `false` to skip without removing the entry
- `max_videos` — per-channel override for `max_videos_per_channel`

---

## How `download-videos.sh` Works

1. Dependency-checks `yt-dlp` and `jq`
2. Reads all settings from `config.json` (all fields have safe defaults)
3. Auto-updates `yt-dlp` to nightly before processing
4. Iterates over enabled channels:
   - Creates `<root_directory>/<channel_name>/Season 01/`
   - Calls `yt-dlp` with stall detection (background process + progress watcher)
   - On stall: kills yt-dlp, waits `stall_retry_wait` seconds, retries up to `stall_max_retries`
   - Skips failed channels if `skip_failed_channels: true`
5. Sends desktop notifications (cron-safe via `DBUS_SESSION_BUS_ADDRESS`)
6. Outputs a summary at the end

**Output filename format:** `Season 01/YYYYMMDD - Title [videoId].ext`  
This matches Jellyfin's TV show library scraping pattern.

---

## Jellyfin Setup

- Managed via Docker Compose (`docker-compose.yml`)
- Requires a `.env` file (copy from `.env.example` if present) with:
  - `JELLYFIN_CONFIG_PATH`, `JELLYFIN_CACHE_PATH`, `MEDIA_PATH`
  - `JELLYFIN_PORT` (default `8096`), `USER_ID`, `GROUP_ID`, `TIMEZONE`
- Media is mounted read-only (`/media:ro`)
- Default access: `http://localhost:8096`

---

## Key Design Decisions

- **All settings in `config.json`** — no hardcoded paths in scripts (scripts have fallback defaults)
- **Stall detection** — yt-dlp is run as a background child; a watcher loop checks progress file mtime; if no progress for `stall_timeout` seconds, it kills and retries
- **Cookies** — `cookies.txt` (Netscape format) is passed to yt-dlp to reduce 403/rate-limit errors
- **Jellyfin TV show naming** — videos go into `Season 01/` with `YYYYMMDD - Title [id].ext` so Jellyfin treats each channel as a TV show
- **cron-safe notifications** — `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` are explicitly exported

---

## Common Tasks & Commands

```bash
# Run the downloader manually
./download-videos.sh

# Use a different config
./download-videos.sh /path/to/other-config.json

# Check all channel URLs are valid
./validate-channels.sh

# Watch live download progress (run in tty3)
./ytdl-monitor.sh

# Jellyfin management
./start-jellyfin.sh
./stop-jellyfin.sh
./update-jellyfin.sh
./backup-jellyfin.sh

# Schedule with cron (daily at 3 AM, logs to file)
0 3 * * * /path/to/YT-DScript/download-videos.sh >> /path/to/YT-DScript/download.log 2>&1
```

---

## Dependencies

| Tool | Install |
|------|---------|
| `yt-dlp` | `sudo wget -O /usr/local/bin/yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp && sudo chmod +x /usr/local/bin/yt-dlp` |
| `ffmpeg` | `sudo apt install ffmpeg` |
| `jq` | `sudo apt install jq` |
| `docker` + `docker-compose` | `sudo apt install docker.io docker-compose` |

---

## Notes
- `config.json` is **gitignored** (user-specific). Use `config.json (copy).template` as a starting point.
- `cookies.txt` is **gitignored** (contains real session tokens). Generate with a browser extension like *Get cookies.txt LOCALLY*.
- `ytdl-monitor.sh` reads `root_directory` from `config.json` dynamically — no hardcoded paths.
- The monitor accepts an optional config path argument: `./ytdl-monitor.sh /path/to/config.json`
