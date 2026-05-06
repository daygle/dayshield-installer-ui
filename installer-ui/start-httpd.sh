#!/bin/sh

set -eu

PORT=8443
FALLBACK_IP="192.168.50.1"
FALLBACK_CIDR="192.168.50.1/24"

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

    if [ "$idx" -eq 2 ]; then
      printf '%s' "$iface"
      return 0
    fi
  done

  [ -n "$first_iface" ] && printf '%s' "$first_iface" && return 0
  return 1
}

iface_ip4() {
  iface="$1"
  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show dev "$iface" scope global 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1
  fi
}

if ! command -v busybox >/dev/null 2>&1 || ! busybox --list 2>/dev/null | grep -qx httpd; then
  printf 'ERROR: busybox httpd is required for CGI script execution\n' >&2
  exit 1
fi

LISTEN_IP=""
IFACE="$(preferred_fallback_iface || true)"
if [ -n "$IFACE" ]; then
  LISTEN_IP="$(iface_ip4 "$IFACE" || true)"
  if [ -z "$LISTEN_IP" ] && command -v ip >/dev/null 2>&1; then
    if ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q "$FALLBACK_CIDR"; then
      LISTEN_IP="$FALLBACK_IP"
    fi
  fi
fi

if [ -z "$LISTEN_IP" ] && command -v ip >/dev/null 2>&1; then
  LISTEN_IP="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1 || true)"
fi

if [ -z "$LISTEN_IP" ]; then
  printf 'WARNING: no dedicated LAN interface IP found; binding to 0.0.0.0 for compatibility\n' >&2
  LISTEN_IP="0.0.0.0"
fi

if busybox httpd --help 2>&1 | grep -q -- "-t"; then
  exec busybox httpd -f -p "$LISTEN_IP:$PORT" -h /installer-ui -c /installer-ui/httpd.conf -t 1800
else
  exec busybox httpd -f -p "$LISTEN_IP:$PORT" -h /installer-ui -c /installer-ui/httpd.conf
fi
