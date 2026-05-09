#!/bin/sh
# reboot.sh - Reboot the system after successful installation.
# Output: JSON { "ok": true }
#
# The reboot is scheduled in a detached background job so CGI shutdown,
# browser disconnects, or HTTP session teardown do not prevent restart.
#
# Must be POSIX-compliant and run as root.

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'
printf '{"ok":true}\n'

schedule_reboot_job() {
  # Run reboot logic in a detached shell so this CGI process can exit cleanly
  # without canceling reboot when the HTTP worker terminates.
  if command -v nohup >/dev/null 2>&1; then
    nohup sh -c '
      sleep 1
      sync

      if command -v systemctl >/dev/null 2>&1; then
        systemctl --no-block reboot >/dev/null 2>&1 ||
        systemctl reboot >/dev/null 2>&1 ||
        reboot -f >/dev/null 2>&1 ||
        /sbin/reboot -f >/dev/null 2>&1 || true
      else
        reboot -f >/dev/null 2>&1 ||
        /sbin/reboot -f >/dev/null 2>&1 || true
      fi

      # Last-resort immediate reboot for minimal live environments.
      if [ -w /proc/sysrq-trigger ]; then
        sync
        echo b > /proc/sysrq-trigger
      fi
    ' >/dev/null 2>&1 &
  else
    sh -c '
    sleep 1
    sync

    if command -v systemctl >/dev/null 2>&1; then
      systemctl --no-block reboot >/dev/null 2>&1 ||
      systemctl reboot >/dev/null 2>&1 ||
      reboot -f >/dev/null 2>&1 ||
      /sbin/reboot -f >/dev/null 2>&1 || true
    else
      reboot -f >/dev/null 2>&1 ||
      /sbin/reboot -f >/dev/null 2>&1 || true
    fi

    # Last-resort immediate reboot for minimal live environments.
    if [ -w /proc/sysrq-trigger ]; then
      sync
      echo b > /proc/sysrq-trigger
    fi
    ' >/dev/null 2>&1 &
  fi
}

schedule_reboot_job
exit 0
