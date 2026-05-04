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

# Derive partition node names (NVMe/MMC use p1/p2 suffix).
case "$DISK" in
  nvme*|mmcblk*)
    EFI_PART="/dev/${DISK}p1"
    ROOT_PART="/dev/${DISK}p2"
    ;;
  *)
    EFI_PART="/dev/${DISK}1"
    ROOT_PART="/dev/${DISK}2"
    ;;
esac

# Inform kernel of new partition table and wait for partition nodes to appear.
partprobe "$DEV" >/dev/null 2>&1 || true

# udevadm settle waits for udev to finish creating /dev nodes; fall back to a
# timed loop in case udevadm is unavailable (busybox environments).
if command -v udevadm >/dev/null 2>&1; then
  udevadm settle --timeout=10 >/dev/null 2>&1 || true
fi

# Extra safety: wait up to 10 s for both partition nodes to appear.
_wait_part() {
  local part="$1" i=0
  while [ ! -b "$part" ] && [ $i -lt 10 ]; do
    sleep 1; i=$(( i + 1 ))
  done
  [ -b "$part" ]
}
if ! _wait_part "${EFI_PART}" || ! _wait_part "${ROOT_PART}"; then
  printf '{"error":"Partition nodes did not appear after partitioning %s"}\n' "$DEV"
  exit 1
fi

printf '{"ok":true}\n'
