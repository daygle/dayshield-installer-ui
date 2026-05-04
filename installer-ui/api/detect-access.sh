#!/bin/sh
# detect-access.sh - Report installer access IPs/URLs for remote clients.
# Output: JSON {
#   "ok": true,
#   "ips": ["x.x.x.x"],
#   "urls": ["http://x.x.x.x:8080/"],
#   "fallback_iface": "ens19",
#   "fallback_assigned": true
# }

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'

IPS_JSON=""
URLS_JSON=""
FIRST_IP=1
FALLBACK_IFACE=""
FALLBACK_ASSIGNED="false"

preferred_fallback_iface() {
  first_iface=""
  idx=0

  for iface_path in /sys/class/net/*; do
    iface=$(basename "$iface_path")
    [ "$iface" = "lo" ] && continue

    case "$iface" in
      lo|sit*|tun*|tap*|docker*|br-*|virbr*|veth*|dummy*) continue ;;
    esac

    real_path=$(readlink -f "$iface_path" 2>/dev/null || printf '%s' "$iface_path")
    case "$real_path" in
      */virtual/*) continue ;;
    esac

    idx=$((idx + 1))
    [ -z "$first_iface" ] && first_iface="$iface"

    # WAN is typically first; prefer second physical NIC for fallback LAN.
    if [ "$idx" -eq 2 ]; then
      printf '%s\n' "$iface"
      return 0
    fi
  done

  [ -n "$first_iface" ] && printf '%s\n' "$first_iface" && return 0
  return 1
}

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
      URLS_JSON="\"${url_safe}\""
      FIRST_IP=0
    else
      IPS_JSON="${IPS_JSON},\"${ip_safe}\""
      URLS_JSON="${URLS_JSON},\"${url_safe}\""
    fi
  done <<EOF
$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}')
EOF
fi

FALLBACK_IFACE=$(preferred_fallback_iface || true)
if [ -n "$FALLBACK_IFACE" ] && command -v ip >/dev/null 2>&1; then
  if ip -4 addr show dev "$FALLBACK_IFACE" 2>/dev/null | grep -q '192\.168\.50\.1/24'; then
    FALLBACK_ASSIGNED="true"
  fi
fi

FALLBACK_IFACE_SAFE=$(printf '%s' "$FALLBACK_IFACE" | sed 's/"/\\"/g')

printf '{"ok":true,"ips":[%s],"urls":[%s],"fallback_iface":"%s","fallback_assigned":%s}\n' \
  "$IPS_JSON" "$URLS_JSON" "$FALLBACK_IFACE_SAFE" "$FALLBACK_ASSIGNED"
