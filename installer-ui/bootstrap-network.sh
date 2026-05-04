#!/bin/sh
# bootstrap-network.sh - Ensure installer web UI is reachable from a remote host.
# Prefer the second physical NIC (LAN) for direct-connect fallback addressing.

set -eu

FALLBACK_IP="192.168.50.1/24"

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

iface_has_global_ip() {
  _iface="$1"
  command -v ip >/dev/null 2>&1 || return 1
  ip -o -4 addr show dev "$_iface" scope global 2>/dev/null | grep -q .
}

IFACE=$(preferred_fallback_iface || true)

# Installer-only console hygiene: suppress martian log spam unconditionally.
# This must run even when DHCP already provided an IP (the early-exit path
# would otherwise skip it and leave noisy kernel logs flooding the console).
if command -v sysctl >/dev/null 2>&1; then
  sysctl -q -w net.ipv4.conf.all.log_martians=0 2>/dev/null || true
  sysctl -q -w net.ipv4.conf.default.log_martians=0 2>/dev/null || true
  if [ -n "${IFACE:-}" ]; then
    sysctl -q -w "net.ipv4.conf.${IFACE}.log_martians=0" 2>/dev/null || true
    sysctl -q -w "net.ipv4.conf.${IFACE}.rp_filter=2" 2>/dev/null || true
  fi
fi

# If chosen fallback NIC already has IPv4, skip fallback address assignment.
if iface_has_global_ip "$IFACE"; then
  exit 0
fi

[ -z "${IFACE:-}" ] && exit 0

# Bring interface up and add fallback address if not already present.
ip link set "$IFACE" up >/dev/null 2>&1 || true
if ! ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q '192\.168\.50\.1/24'; then
  ip -4 addr add "$FALLBACK_IP" dev "$IFACE" >/dev/null 2>&1 || true
fi

exit 0
