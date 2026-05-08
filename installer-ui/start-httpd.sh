#!/bin/sh

set -eu

PORT=8443

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

# Bind on all interfaces for installer reliability.  The live environment may
# have multiple NICs (or transient DHCP timing), so binding to one detected IP
# can make the web UI unreachable from another interface.
LISTEN_IP="0.0.0.0"

if busybox httpd --help 2>&1 | grep -q -- "-t"; then
  exec busybox httpd -f -p "$LISTEN_IP:$PORT" -h /installer-ui -c /installer-ui/httpd.conf -t 1800
else
  exec busybox httpd -f -p "$LISTEN_IP:$PORT" -h /installer-ui -c /installer-ui/httpd.conf
fi
