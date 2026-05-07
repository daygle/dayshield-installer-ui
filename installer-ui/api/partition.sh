#!/bin/sh
# shellcheck shell=ash
# partition.sh - Create GPT partition table with BIOS boot + EFI + root partitions
# Query string params: disk=<name>   (e.g. disk=sda)
# Output: JSON  { "ok": true } | { "error": "message" }
#
# Partition layout:
#   Partition 1:    1 MiB - BIOS Boot Partition (EF02, unformatted)
#   Partition 2:  512 MiB - EFI System (FAT32)
#   Partition 3:  Remaining - Linux filesystem (ext4)
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

# Strip /dev/ prefix if caller included it, then enforce a strict
# device-name whitelist to prevent path traversal.
DISK=$(printf '%s' "$DISK" | sed 's|^/dev/||')
if ! printf '%s' "$DISK" | grep -Eq '^[a-zA-Z0-9]+$'; then
  printf '{"error":"Invalid disk name"}\n'
  exit 1
fi
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
        --new=1:1MiB:+1MiB --typecode=1:EF02 --change-name=1:"BIOS Boot" \
        --new=2:0:+512M    --typecode=2:EF00 --change-name=2:"EFI System" \
        --new=3:0:0        --typecode=3:8300 --change-name=3:"Linux Root" \
        "$DEV" >/dev/null 2>&1; then
    printf '{"error":"sgdisk failed on %s"}\n' "$DEV"
    exit 1
  fi

# ── Fallback: parted ─────────────────────────────────────────────
elif command -v parted >/dev/null 2>&1; then
  if ! parted -s "$DEV" \
        mklabel gpt \
        mkpart primary 1MiB 2MiB \
        set 1 bios_grub on \
        mkpart primary fat32 2MiB 514MiB \
        set 2 esp on \
        mkpart primary ext4 514MiB 100% >/dev/null 2>&1; then
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
    EFI_PART="/dev/${DISK}p2"
    ROOT_PART="/dev/${DISK}p3"
    ;;
  *)
    EFI_PART="/dev/${DISK}2"
    ROOT_PART="/dev/${DISK}3"
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
