#!/bin/bash
# update-jellyfin.sh
# Update Jellyfin to latest version

echo "🔄 Updating Jellyfin Media Server..."

# Pull latest image
if command -v docker-compose &> /dev/null; then
    docker-compose pull jellyfin
elif command -v docker &> /dev/null; then
    docker compose pull jellyfin
fi

# Restart with new image
./stop-jellyfin.sh
sleep 2
./start-jellyfin.sh

echo "✅ Jellyfin updated successfully!"