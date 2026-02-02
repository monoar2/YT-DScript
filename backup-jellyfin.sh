#!/bin/bash
# backup-jellyfin.sh
# Backup Jellyfin configuration

set -e

BACKUP_DIR="./backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="jellyfin_backup_${TIMESTAMP}.tar.gz"

source .env

echo "💾 Backing up Jellyfin configuration..."

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Stop Jellyfin first
echo "🛑 Stopping Jellyfin..."
./stop-jellyfin.sh
sleep 5

# Create backup
echo "📦 Creating backup..."
tar -czf "$BACKUP_DIR/$BACKUP_NAME" \
    -C "$(dirname "$JELLYFIN_CONFIG_PATH")" \
    "$(basename "$JELLYFIN_CONFIG_PATH")" \
    -C "$(dirname "$JELLYFIN_CACHE_PATH")" \
    "$(basename "$JELLYFIN_CACHE_PATH")" 2>/dev/null || true

# Start Jellyfin again
echo "🚀 Restarting Jellyfin..."
./start-jellyfin.sh

echo "✅ Backup created: $BACKUP_DIR/$BACKUP_NAME"
echo "📏 Size: $(du -h "$BACKUP_DIR/$BACKUP_NAME" | cut -f1)"