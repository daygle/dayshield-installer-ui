#!/bin/sh

set -eu

PORT=8443

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
