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

label_device() {
  blkid -L "$1" 2>/dev/null || true
}

root_slot_device() {
  dev=$(label_device "$1")
  [ -n "$dev" ] || dev=$(label_device "$2")
  printf '%s' "$dev"
}

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

  # Detect if the disk already has partitions or filesystem signatures.
  part_count=$(lsblk -n -o NAME,TYPE "/dev/${name}" 2>/dev/null | awk '$2 == "part" {count++} END {print count+0}')
  has_data=false
  if [ "$part_count" -gt 0 ]; then
    has_data=true
  elif command -v blkid >/dev/null 2>&1 && blkid -o value "/dev/${name}" >/dev/null 2>&1; then
    has_data=true
  fi

  has_ab_install=false
  if command -v blkid >/dev/null 2>&1; then
    root_a=$(root_slot_device DS_PRIMARY DAYSHIELD_ROOT_A)
    root_b=$(root_slot_device DS_SECONDARY DAYSHIELD_ROOT_B)
    boot_part=$(blkid -L DAYSHIELD_BOOT 2>/dev/null || true)
    if [ -n "$root_a" ] && [ -n "$root_b" ] && [ -n "$boot_part" ]; then
      ab_matches=0
      for dev in "$root_a" "$root_b" "$boot_part"; do
        pkname=$(lsblk -ndo PKNAME "$dev" 2>/dev/null || true)
        if [ "$pkname" = "$name" ]; then
          ab_matches=$((ab_matches + 1))
        fi
      done
      [ "$ab_matches" -eq 3 ] && has_ab_install=true
    fi
  fi

  entry="{\"name\":\"${name_safe}\",\"size\":\"${size_safe}\",\"type\":\"${type_safe}\",\"has_data\":${has_data},\"has_ab_install\":${has_ab_install}}"

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
