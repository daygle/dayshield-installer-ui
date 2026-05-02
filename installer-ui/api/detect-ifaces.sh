#!/bin/sh
# detect-ifaces.sh — List available network interfaces (excludes loopback/virtual)
# Output: JSON  { "ok": true, "ifaces": ["eth0", "enp3s0", ...] }
#
# Called by the installer web UI via busybox httpd CGI.
# Must be POSIX-compliant.

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'

IFACES_JSON=""
FIRST=1

# /sys/class/net is present on all Linux systems
if [ -d /sys/class/net ]; then
  for iface_path in /sys/class/net/*; do
    iface=$(basename "$iface_path")

    # Skip loopback
    [ "$iface" = "lo" ] && continue

    # Skip virtual/special interfaces
    case "$iface" in
      lo|sit*|tun*|tap*|docker*|br-*|virbr*|veth*|dummy*) continue ;;
    esac

    # Confirm it's a physical/ethernet-like interface by checking absence of
    # the "virtual" symlink in /sys/devices/virtual
    real_path=$(readlink -f "$iface_path" 2>/dev/null || printf '%s' "$iface_path")
    case "$real_path" in
      */virtual/*) continue ;;
    esac

    iface_safe=$(printf '%s' "$iface" | sed 's/"/\\"/g')

    if [ "$FIRST" -eq 1 ]; then
      IFACES_JSON="\"${iface_safe}\""
      FIRST=0
    else
      IFACES_JSON="${IFACES_JSON},\"${iface_safe}\""
    fi
  done
else
  # Fallback: ip link or ifconfig
  if command -v ip >/dev/null 2>&1; then
    while IFS= read -r line; do
      iface=$(printf '%s' "$line" | awk -F': ' '{print $2}' | awk '{print $1}')
      [ -z "$iface" ] && continue
      case "$iface" in lo|sit*|tun*|tap*|docker*|br-*|virbr*|veth*) continue ;; esac
      iface_safe=$(printf '%s' "$iface" | sed 's/"/\\"/g')
      if [ "$FIRST" -eq 1 ]; then
        IFACES_JSON="\"${iface_safe}\""
        FIRST=0
      else
        IFACES_JSON="${IFACES_JSON},\"${iface_safe}\""
      fi
    done << EOF
$(ip -o link show 2>/dev/null | grep -v 'link/loopback')
EOF
  fi
fi

printf '{"ok":true,"ifaces":[%s]}\n' "${IFACES_JSON}"
