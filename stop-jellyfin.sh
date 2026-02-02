#!/bin/bash
# stop-jellyfin.sh
# Stop Jellyfin gracefully

echo "🛑 Stopping Jellyfin Media Server..."

if command -v docker-compose &> /dev/null; then
    docker-compose down
elif command -v docker &> /dev/null; then
    docker compose down
fi

echo "✅ Jellyfin stopped successfully!"