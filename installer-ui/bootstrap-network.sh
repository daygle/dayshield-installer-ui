#!/bin/sh
# bootstrap-network.sh - Ensure installer web UI is reachable from a remote host.
# If no global IPv4 exists on physical interfaces, assign a deterministic fallback
# address for direct-connect installs.

set -eu

FALLBACK_IP="192.168.50.1/24"

has_global_ip() {
  command -v ip >/dev/null 2>&1 || return 1
  ip -o -4 addr show scope global 2>/dev/null | grep -q .
}

first_physical_iface() {
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

    printf '%s\n' "$iface"
    return 0
  done
  return 1
}

# If DHCP or static IPv4 already exists, do nothing.
if has_global_ip; then
  exit 0
fi

IFACE=$(first_physical_iface || true)
[ -z "${IFACE:-}" ] && exit 0

# Bring interface up and add fallback address if not already present.
ip link set "$IFACE" up >/dev/null 2>&1 || true
if ! ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q '192\.168\.50\.1/24'; then
  ip -4 addr add "$FALLBACK_IP" dev "$IFACE" >/dev/null 2>&1 || true
fi

exit 0
