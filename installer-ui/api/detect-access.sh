#!/bin/sh
# detect-access.sh - Report installer access IPs/URLs for remote clients.
# Output: JSON { "ok": true, "ips": ["x.x.x.x"], "urls": ["http://x.x.x.x:8080/"] }

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'

IPS_JSON=""
URLS_JSON="\"http://127.0.0.1:8080/\""
FIRST_IP=1

if command -v ip >/dev/null 2>&1; then
  while IFS= read -r cidr; do
    ip4=$(printf '%s' "$cidr" | cut -d/ -f1)
    [ -z "$ip4" ] && continue

    # Skip loopback and unspecified addresses.
    case "$ip4" in
      127.*|0.*) continue ;;
    esac

    ip_safe=$(printf '%s' "$ip4" | sed 's/"/\\"/g')
    url_safe=$(printf 'http://%s:8080/' "$ip4" | sed 's/"/\\"/g')

    if [ "$FIRST_IP" -eq 1 ]; then
      IPS_JSON="\"${ip_safe}\""
      URLS_JSON="${URLS_JSON},\"${url_safe}\""
      FIRST_IP=0
    else
      IPS_JSON="${IPS_JSON},\"${ip_safe}\""
      URLS_JSON="${URLS_JSON},\"${url_safe}\""
    fi
  done <<EOF
$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}')
EOF
fi

printf '{"ok":true,"ips":[%s],"urls":[%s]}\n' "$IPS_JSON" "$URLS_JSON"
