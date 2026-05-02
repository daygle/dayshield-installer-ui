#!/bin/sh
# reboot.sh — Reboot the system after successful installation
# Output: JSON  { "ok": true }   (sent before systemctl reboot)
#
# The HTTP server will be killed when the system reboots, so the
# client-side JavaScript expects a network error after this call.
#
# Must be POSIX-compliant and run as root.

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'
printf '{"ok":true}\n'

# Flush output before rebooting
sync

# Give the HTTP response a moment to be sent before the kernel tears down
sleep 1

# Reboot the system
if command -v systemctl >/dev/null 2>&1; then
  systemctl reboot
else
  reboot
fi
