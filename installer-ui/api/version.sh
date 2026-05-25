#!/bin/sh
# version.sh - Report the installed rootfs version.
# Output: JSON { "ok": true, "version": "1.2.3" }
#
# Called by the installer web UI via busybox httpd CGI.
# Must be POSIX-compliant.

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'

VERSION_FILE="/etc/dayshield/version"

if [ -f "${VERSION_FILE}" ]; then
  ver=$(cat "${VERSION_FILE}" | tr -d '[:space:]')
else
  ver="unknown"
fi

ver_safe=$(printf '%s' "${ver}" | sed 's/"/\\"/g')
printf '{"ok":true,"version":"%s"}\n' "${ver_safe}"
