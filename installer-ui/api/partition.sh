#!/bin/sh
# partition.sh - Create the DayShield RAUC GPT partition layout.
# Query string params: disk=<name> (for example: sda)

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'

json_error() {
  msg=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"error":"%s"}\n' "$msg"
  exit 1
}

decode_urlencoded() {
  _raw=$1
  printf '%s' "$_raw" | awk '
    BEGIN {
      for (i = 0; i <= 255; i++) {
        dec[sprintf("%02x", i)] = sprintf("%c", i)
        dec[sprintf("%02X", i)] = sprintf("%c", i)
      }
    }
    {
      gsub(/\+/, " ")
      out = ""
      while (match($0, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
        out = out substr($0, 1, RSTART - 1) dec[substr($0, RSTART + 1, 2)]
        $0  = substr($0, RSTART + RLENGTH)
      }
      printf "%s%s", out, $0
    }'
}

query_param() {
  printf '%s' "$1" | tr '&' '\n' | sed -n "s/^$2=//p" | head -n1
}

DISK=""
if [ -n "${QUERY_STRING:-}" ]; then
  DISK=$(decode_urlencoded "$(query_param "$QUERY_STRING" disk)")
fi

[ -n "$DISK" ] || json_error "Missing required parameter: disk"
DISK=$(printf '%s' "$DISK" | sed 's|^/dev/||')
printf '%s' "$DISK" | grep -Eq '^[a-zA-Z0-9]+$' || json_error "Invalid disk name"

DEV="/dev/${DISK}"
[ -b "$DEV" ] || json_error "Device not found: $DEV"

if awk -v dev="$DEV" '$1 ~ ("^" dev) { found=1 } END { exit(found ? 0 : 1) }' /proc/mounts; then
  json_error "Device $DEV is currently mounted/in use (likely live boot media). Select a different install disk."
fi

command -v parted >/dev/null 2>&1 || json_error "parted not found"

wipefs -a "$DEV" >/dev/null 2>&1 || true

# Partitions: BIOS boot (1-2MiB), EFI (2-514MiB), BOOT (514MiB-1538MiB),
# DS_ROOT_A (1538MiB-5634MiB, 4 GiB primary OS slot),
# DS_ROOT_B (5634MiB-9730MiB, 4 GiB update slot for fail-safe updates),
# STATE (9730MiB-100%) for persistent /var.
parted_err=$(parted -s "$DEV" \
  mklabel gpt \
  mkpart "BIOS" 1MiB 2MiB \
  set 1 bios_grub on \
  mkpart "EFI" fat32 2MiB 514MiB \
  set 2 esp on \
  mkpart "BOOT" ext4 514MiB 1538MiB \
  mkpart "ROOT_A" ext4 1538MiB 5634MiB \
  mkpart "ROOT_B" ext4 5634MiB 9730MiB \
  mkpart "STATE" ext4 9730MiB 100% 2>&1) || json_error "parted failed: $parted_err"

partprobe "$DEV" >/dev/null 2>&1 || true
if command -v udevadm >/dev/null 2>&1; then
  udevadm settle --timeout=10 >/dev/null 2>&1 || true
fi

part_node() {
  case "$DISK" in
    nvme*|mmcblk*) printf '/dev/%sp%s' "$DISK" "$1" ;;
    *) printf '/dev/%s%s' "$DISK" "$1" ;;
  esac
}

wait_part() {
  part="$1"
  i=0
  while [ ! -b "$part" ] && [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
  done
  [ -b "$part" ]
}

for number in 2 3 4 5 6; do
  part=$(part_node "$number")
  wait_part "$part" || json_error "Partition node did not appear after partitioning: $part"
done

printf '{"ok":true}\n'
