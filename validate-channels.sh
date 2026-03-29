#!/bin/bash
# Validates all channel URLs in config.json by checking HTTP status.
# Reports whether each channel handle resolves on YouTube (200 = found, 404 = not found).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.json"

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found — install with: sudo apt install jq"
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "ERROR: curl not found"
  exit 1
fi

PASS=0
FAIL=0
WARN=0
TOTAL=0

printf "\n%-30s %-50s %s\n" "CHANNEL NAME" "URL" "STATUS"
printf "%s\n" "$(printf '%.0s─' {1..90})"

while IFS= read -r line; do
  name=$(echo "$line" | jq -r '.name')
  url=$(echo "$line"  | jq -r '.url')
  enabled=$(echo "$line" | jq -r '.enabled // true')
  TOTAL=$((TOTAL + 1))

  if [[ "$enabled" == "false" ]]; then
    printf "%-30s %-50s %s\n" "${name:0:30}" "${url:0:50}" "⏭  disabled"
    WARN=$((WARN + 1))
    continue
  fi

  http_code=$(curl -s -o /dev/null -w "%{http_code}" -L --max-time 10 "$url" 2>/dev/null)

  case "$http_code" in
    200)
      printf "%-30s %-50s %s\n" "${name:0:30}" "${url:0:50}" "✅ found"
      PASS=$((PASS + 1))
      ;;
    404)
      printf "%-30s %-50s %s\n" "${name:0:30}" "${url:0:50}" "❌ NOT FOUND (404)"
      FAIL=$((FAIL + 1))
      ;;
    000)
      printf "%-30s %-50s %s\n" "${name:0:30}" "${url:0:50}" "⚠️  timeout / no response"
      WARN=$((WARN + 1))
      ;;
    *)
      printf "%-30s %-50s %s\n" "${name:0:30}" "${url:0:50}" "⚠️  unexpected HTTP $http_code"
      WARN=$((WARN + 1))
      ;;
  esac

done < <(jq -c '.channels[]' "$CONFIG")

printf "%s\n\n" "$(printf '%.0s─' {1..90})"
printf "Checked %d channels — ✅ %d found   ❌ %d not found   ⚠️  %d warnings\n\n" \
  "$TOTAL" "$PASS" "$FAIL" "$WARN"
