#!/bin/sh
# partition.sh - Create GPT partition table with EFI + root partitions
# Query string params: disk=<name>   (e.g. disk=sda)
# Output: JSON  { "ok": true } | { "error": "message" }
#
# Partition layout:
#   Partition 1:  512 MiB - EFI System (FAT32)
#   Partition 2:  Remaining - Linux filesystem (ext4)
#
# Requires: sgdisk (gdisk package) or parted as fallback.
# Must be POSIX-compliant and run as root.

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'

# ── Parse CGI query string ────────────────────────────────────────
# busybox httpd sets QUERY_STRING for GET requests
DISK=""
if [ -n "${QUERY_STRING:-}" ]; then
  DISK=$(printf '%s' "$QUERY_STRING" | sed 's/.*disk=\([^&]*\).*/\1/' | sed 's/%2F/\//g')
fi

# ── Validate ──────────────────────────────────────────────────────
if [ -z "$DISK" ]; then
  printf '{"error":"Missing required parameter: disk"}\n'
  exit 1
fi

# Strip /dev/ prefix if caller included it
DISK=$(printf '%s' "$DISK" | sed 's|^/dev/||')
DEV="/dev/${DISK}"

if [ ! -b "$DEV" ]; then
  printf '{"error":"Device not found: %s"}\n' "$DEV"
  exit 1
fi

# ── Wipe existing signatures ──────────────────────────────────────
wipefs -a "$DEV" >/dev/null 2>&1 || true

# ── Partition with sgdisk (preferred) ────────────────────────────
if command -v sgdisk >/dev/null 2>&1; then
  if ! sgdisk \
        --zap-all \
        --new=1:0:+512M  --typecode=1:EF00 --change-name=1:"EFI System" \
        --new=2:0:0       --typecode=2:8300 --change-name=2:"Linux Root" \
        "$DEV" >/dev/null 2>&1; then
    printf '{"error":"sgdisk failed on %s"}\n' "$DEV"
    exit 1
  fi

# ── Fallback: parted ─────────────────────────────────────────────
elif command -v parted >/dev/null 2>&1; then
  if ! parted -s "$DEV" \
        mklabel gpt \
        mkpart primary fat32 1MiB 513MiB \
        set 1 esp on \
        mkpart primary ext4 513MiB 100% >/dev/null 2>&1; then
    printf '{"error":"parted failed on %s"}\n' "$DEV"
    exit 1
  fi

else
  printf '{"error":"Neither sgdisk nor parted found"}\n'
  exit 1
fi

# Inform kernel of new partition table
partprobe "$DEV" >/dev/null 2>&1 || true
sleep 1

printf '{"ok":true}\n'
