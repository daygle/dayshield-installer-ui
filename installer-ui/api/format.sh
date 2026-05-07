#!/bin/sh
# format.sh - Format partitions created by partition.sh
# Query string params: disk=<name>   (e.g. disk=sda)
# Output: JSON  { "ok": true } | { "error": "message" }
#
# Actions:
#   /dev/<disk>2  →  FAT32 (EFI)
#   /dev/<disk>3  →  ext4  (root, metadata checksum enabled)
#
# Must be POSIX-compliant and run as root.

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'

# ── Parse CGI query string ────────────────────────────────────────
DISK=""
if [ -n "${QUERY_STRING:-}" ]; then
  DISK=$(printf '%s' "$QUERY_STRING" | sed 's/.*disk=\([^&]*\).*/\1/' | sed 's/%2F/\//g')
fi

if [ -z "$DISK" ]; then
  printf '{"error":"Missing required parameter: disk"}\n'
  exit 1
fi

DISK=$(printf '%s' "$DISK" | sed 's|^/dev/||')
if ! printf '%s' "$DISK" | grep -Eq '^[a-zA-Z0-9]+$'; then
  printf '{"error":"Invalid disk name"}\n'
  exit 1
fi
EFI_PART="/dev/${DISK}2"
ROOT_PART="/dev/${DISK}3"

# Handle NVMe partition naming (nvme0n1p1 instead of nvme0n1 + 1)
case "$DISK" in
  nvme*|mmcblk*)
    EFI_PART="/dev/${DISK}p2"
    ROOT_PART="/dev/${DISK}p3"
    ;;
esac

# ── Validate ──────────────────────────────────────────────────────
for part in "$EFI_PART" "$ROOT_PART"; do
  if [ ! -b "$part" ]; then
    printf '{"error":"Partition not found: %s"}\n' "$part"
    exit 1
  fi
done

# ── Format EFI partition as FAT32 ────────────────────────────────
if ! mkfs.fat -F32 -n "EFI" "$EFI_PART" >/dev/null 2>&1; then
  printf '{"error":"Failed to format EFI partition %s as FAT32"}\n' "$EFI_PART"
  exit 1
fi

# ── Format root partition as ext4 ────────────────────────────────
if ! mkfs.ext4 -F -L "dayshield-root" \
     -O "^64bit,metadata_csum" \
     -m 1 \
     "$ROOT_PART" >/dev/null 2>&1; then
  printf '{"error":"Failed to format root partition %s as ext4"}\n' "$ROOT_PART"
  exit 1
fi

printf '{"ok":true}\n'
