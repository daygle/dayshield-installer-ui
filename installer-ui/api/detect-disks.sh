#!/bin/sh
# detect-disks.sh - List available block disks (excludes loop/rom/ram)
# Output: JSON  { "ok": true, "disks": [ { "name": "sda", "size": "256G", "type": "disk" }, ... ] }
#
# Called by the installer web UI via busybox httpd CGI.
# Must be POSIX-compliant.

set -eu

# CGI header (busybox httpd invokes scripts as CGI)
printf 'Content-Type: application/json\r\n'
printf '\r\n'

# Require lsblk
if ! command -v lsblk >/dev/null 2>&1; then
  printf '{"error":"lsblk not found"}\n'
  exit 1
fi

# Collect disk list, exclude loop/rom/ram devices
DISKS_JSON=""
FIRST=1

while IFS= read -r line; do
  # lsblk columns: NAME SIZE TYPE
  name=$(printf '%s' "$line" | awk '{print $1}')
  size=$(printf '%s' "$line" | awk '{print $2}')
  type=$(printf '%s' "$line" | awk '{print $3}')

  # Skip non-disk entries and virtual devices
  case "$name" in
    loop*|ram*|rom*|sr*|fd*) continue ;;
  esac

  [ "$type" = "disk" ] || continue

  # Escape values for JSON
  name_safe=$(printf '%s' "$name" | sed 's/"/\\"/g')
  size_safe=$(printf '%s' "$size" | sed 's/"/\\"/g')
  type_safe=$(printf '%s' "$type" | sed 's/"/\\"/g')

  entry="{\"name\":\"${name_safe}\",\"size\":\"${size_safe}\",\"type\":\"${type_safe}\"}"

  if [ "$FIRST" -eq 1 ]; then
    DISKS_JSON="${entry}"
    FIRST=0
  else
    DISKS_JSON="${DISKS_JSON},${entry}"
  fi
done << EOF
$(lsblk -d -n -o NAME,SIZE,TYPE 2>/dev/null)
EOF

printf '{"ok":true,"disks":[%s]}\n' "${DISKS_JSON}"
