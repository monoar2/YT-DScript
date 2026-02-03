#!/bin/bash
# start-jellyfin.sh
# Start Jellyfin with environment variables

set -e  # Exit on error

echo "🚀 Starting Jellyfin Media Server..."

# Check if .env file exists
if [ ! -f .env ]; then
    echo "❌ .env file not found!"
    echo "📝 Please create .env file from .env.example"
    echo "💡 Run: cp .env.example .env && nano .env"
    exit 1
fi

# Check if docker-compose is installed
if ! command -v docker-compose &> /dev/null && ! command -v docker compose &> /dev/null; then
    echo "❌ Docker Compose not found!"
    echo "📦 Install with: sudo apt install docker-compose"
    exit 1
fi

# Load environment variables
source .env

# Validate required variables
REQUIRED_VARS=("JELLYFIN_CONFIG_PATH" "JELLYFIN_CACHE_PATH" "MEDIA_PATH")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Missing required variable: $var"
        exit 1
    fi
done

# Create directories if they don't exist
echo "📁 Creating directories..."
mkdir -p "$JELLYFIN_CONFIG_PATH"
mkdir -p "$JELLYFIN_CACHE_PATH"
mkdir -p "$MEDIA_PATH"

# Set permissions
echo "🔐 Setting permissions..."
chown -R ${USER_ID}:${GROUP_ID} "$JELLYFIN_CONFIG_PATH"
chown -R ${USER_ID}:${GROUP_ID} "$JELLYFIN_CACHE_PATH"
chmod -R 755 "$JELLYFIN_CONFIG_PATH"
chmod -R 755 "$JELLYFIN_CACHE_PATH"

# Start Jellyfin
echo "🐳 Starting Docker containers..."
if command -v docker-compose &> /dev/null; then
    docker-compose up -d
elif command -v docker &> /dev/null; then
    docker compose up -d
fi

echo ""
echo "✅ Jellyfin started successfully!"
echo "🌐 Access at: http://localhost:${JELLYFIN_PORT:-8096}"
echo ""
echo "📋 Useful commands:"
echo "   View logs: docker-compose logs -f jellyfin"
echo "   Stop: docker-compose down"
echo "   Restart: docker-compose restart jellyfin"
echo "   Update: docker-compose pull && docker-compose up -d"