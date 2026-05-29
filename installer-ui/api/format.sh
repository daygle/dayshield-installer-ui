#!/bin/sh
# format.sh - Format the DayShield image-based update partition layout.
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

part_node() {
  case "$DISK" in
    nvme*|mmcblk*) printf '/dev/%sp%s' "$DISK" "$1" ;;
    *) printf '/dev/%s%s' "$DISK" "$1" ;;
  esac
}

EFI_PART=$(part_node 2)
BOOT_PART=$(part_node 3)
ROOT_A_PART=$(part_node 4)
ROOT_B_PART=$(part_node 5)
STATE_PART=$(part_node 6)

for part in "$EFI_PART" "$BOOT_PART" "$ROOT_A_PART" "$ROOT_B_PART" "$STATE_PART"; do
  [ -b "$part" ] || json_error "Partition not found: $part"
done

# Labels match the values the dayshield-core update flow and GRUB config look up:
#   DS_EFI / DAYSHIELD_BOOT / DS_ROOT_A / DS_ROOT_B / DS_STATE.
err=$(mkfs.fat -F32 -n "DS_EFI" "$EFI_PART" 2>&1) || json_error "Failed to format EFI partition $EFI_PART: $err"
err=$(mkfs.ext4 -F -L "DAYSHIELD_BOOT" -O "^64bit,metadata_csum" -m 1 "$BOOT_PART" 2>&1) || json_error "Failed to format boot partition $BOOT_PART: $err"
err=$(mkfs.ext4 -F -L "DS_ROOT_A" -O "^64bit,metadata_csum" -m 1 "$ROOT_A_PART" 2>&1) || json_error "Failed to format root slot A $ROOT_A_PART: $err"
err=$(mkfs.ext4 -F -L "DS_ROOT_B" -O "^64bit,metadata_csum" -m 1 "$ROOT_B_PART" 2>&1) || json_error "Failed to format root slot B $ROOT_B_PART: $err"
err=$(mkfs.ext4 -F -L "DS_STATE" -O "^64bit,metadata_csum" -m 1 "$STATE_PART" 2>&1) || json_error "Failed to format persistent state partition $STATE_PART: $err"

printf '{"ok":true}\n'
