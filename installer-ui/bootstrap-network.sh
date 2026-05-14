#!/bin/sh
# bootstrap-network.sh - Prepare network for installer web UI access.
#
# The web installer is always reachable at http://192.168.50.1:8443/.
# This address is assigned to the second physical NIC (the future LAN port)
# so the operator can connect a laptop directly to that port and reach the
# installer. If only one NIC is present, that NIC is used instead.
#
# This address exists only in the live session; installer-finalize.sh removes
# all live networkd config before writing the installed system's network plan.

set -eu

INSTALLER_IP="192.168.50.1/24"

preferred_iface() {
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

    # WAN is typically first; assign installer address to second NIC (future LAN).
    if [ "$idx" -eq 2 ]; then
      printf '%s\n' "$iface"
      return 0
    fi
  done

  # Only one NIC present - use it.
  [ -n "$first_iface" ] && printf '%s\n' "$first_iface" && return 0
  return 1
}

IFACE=$(preferred_iface || true)

# Suppress martian log spam on the live installer console.
if command -v sysctl >/dev/null 2>&1; then
  sysctl -q -w net.ipv4.conf.all.log_martians=0 2>/dev/null || true
  sysctl -q -w net.ipv4.conf.default.log_martians=0 2>/dev/null || true
  if [ -n "${IFACE:-}" ]; then
    sysctl -q -w "net.ipv4.conf.${IFACE}.log_martians=0" 2>/dev/null || true
    sysctl -q -w "net.ipv4.conf.${IFACE}.rp_filter=2" 2>/dev/null || true
  fi
fi

# Open port 8443 on all interfaces for the live installer session.
# The base nftables ruleset has LAN_IF=lo at live-boot time, so port 8443
# is blocked until this temporary rule is inserted.
_open_installer_port() {
  if ! command -v nft >/dev/null 2>&1; then return; fi
  if ! nft list table ip filter >/dev/null 2>&1; then return; fi
  if nft list chain ip filter input 2>/dev/null | grep -q 'dayshield-installer-web'; then return; fi
  nft insert rule ip filter input tcp dport 8443 ct state new accept comment "dayshield-installer-web" 2>/dev/null || true
}
_open_installer_port

[ -z "${IFACE:-}" ] && exit 0

# Bring the interface up and assign the fixed installer address.
ip link set "$IFACE" up >/dev/null 2>&1 || true
if ! ip -4 addr show dev "$IFACE" 2>/dev/null | grep -qF "192.168.50.1/24"; then
  ip -4 addr add "$INSTALLER_IP" dev "$IFACE" >/dev/null 2>&1 || true
fi

exit 0
