# YT-DScript
Script to automatically download videos from youtube

Designed for **long-term archiving** and **cron automation**.

---

##  Requirements

- Linux (Ubuntu, Debian, Mint, etc.)
- Bash
- `yt-dlp`
- `ffmpeg`
- `jq`

---

## 🚀 Installation

### 1️⃣ Install `yt-dlp` (recommended standalone binary)

```bash
sudo wget -O /usr/local/bin/yt-dlp \
  https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp
sudo chmod +x /usr/local/bin/yt-dlp

Verify:

yt-dlp --version

2️⃣ Install dependencies

sudo apt update
sudo apt install -y ffmpeg jq

Verify:

ffmpeg -version
jq --version

⚙️ Configuration

Create a file named config.json:

{
  "delay": 10,
  "channels": [
    {
      "url": "https://www.youtube.com/@GameGrumps",
      "fetch_only_new": true
    },
    {
      "url": "https://www.youtube.com/@markiplier",
      "fetch_only_new": true
    }
  ]
}

🔍 Config options
Field	Description
delay	Seconds to wait between channels
url	Channel homepage URL (NOT /videos)
fetch_only_new	Download only new uploads
📝 Script Setup

Save the script as:

download_channel_videos.sh

Make it executable:

chmod +x download_channel_videos.sh

▶️ Usage

Run from the directory containing config.json:

./download_channel_videos.sh config.json

What it does:

    Creates one folder per channel

    Downloads only missing videos

    Skips already-downloaded ones

    Produces:

        MP4 video files

        downloaded.txt (tracking)

        playlist.xspf (VLC-compatible)

You can safely re-run the script anytime.
🔄 Updating yt-dlp

The script automatically updates yt-dlp before running.

Manual update:

yt-dlp -U

⏱️ Automating with Cron (Optional)

Edit crontab:

crontab -e

Example (daily at 3 AM):

0 3 * * * /home/youruser/ytdlp/download_channel_videos.sh /home/youruser/ytdlp/config.json >> /home/youruser/ytdlp/cron.log 2>&1

⚠️ Use absolute paths in cron.
🧠 Troubleshooting
❌ Some videos download as MKV

Fixed by:

    Explicit MP4 format selection

    Forcing ffmpeg remux

Make sure ffmpeg is installed.
❌ HTTP 403 / Forbidden errors

Handled by:

    Fragment retries

    Randomized sleep

    Download rate limiting

If it still happens:

    Wait 15–30 minutes

    Re-run the script (resume is automatic)

❌ yt-dlp: command not found

sudo ln -s /usr/local/bin/yt-dlp /usr/bin/yt-dlp

🛡️ Safety & Ethics

    Public content only

    Respects rate limits

    Designed to avoid ham
