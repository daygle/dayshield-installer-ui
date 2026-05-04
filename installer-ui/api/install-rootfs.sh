#!/bin/sh
# install-rootfs.sh - Mount target partitions and extract the DayShield rootfs
# Query string params: disk=<name>   (e.g. disk=sda)
# Output: JSON  { "ok": true } | { "error": "message" }
#
# Expects:
#   /run/installer/rootfs.tar.zst   - root filesystem archive
#   /run/installer/defaults/        - optional /etc/dayshield overlay
#
# Mount layout:
#   /mnt/target       - root partition  (/dev/<disk>2)
#   /mnt/target/boot/efi  - EFI partition  (/dev/<disk>1)
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
EFI_PART="/dev/${DISK}1"
ROOT_PART="/dev/${DISK}2"
case "$DISK" in nvme*|mmcblk*) EFI_PART="/dev/${DISK}p1"; ROOT_PART="/dev/${DISK}p2" ;; esac

TARGET="/mnt/target"
DEFAULTS_DIR="/run/installer/defaults"

# ── Locate rootfs archive ─────────────────────────────────────────
# Search in priority order:
#   1. Pre-staged at /run/installer/ (explicit setup by admin)
#   2. On the live medium mounted by live-boot (Debian)
#   3. On the live medium mounted by dracut dmsquash-live
#   4. By scanning for a block device with the DAYSHIELD label
find_rootfs() {
  for candidate in \
    "/run/installer/rootfs.tar.zst" \
    "/lib/live/mount/medium/installer/rootfs.tar.zst" \
    "/run/live/medium/installer/rootfs.tar.zst" \
    "/media/cdrom/installer/rootfs.tar.zst" \
    "/media/live/installer/rootfs.tar.zst"
  do
    [ -f "$candidate" ] && printf '%s' "$candidate" && return 0
  done

  # Last resort: scan block devices for the DAYSHIELD label and mount it
  _dev=$(blkid -t LABEL=DAYSHIELD -o device 2>/dev/null | head -n1)
  if [ -n "$_dev" ]; then
    _mp=$(mktemp -d)
    if mount -o ro "$_dev" "$_mp" 2>/dev/null; then
      if [ -f "${_mp}/installer/rootfs.tar.zst" ]; then
        # Copy to RAM so we can unmount the ISO
        cp "${_mp}/installer/rootfs.tar.zst" /tmp/rootfs.tar.zst
        umount "$_mp" 2>/dev/null || true
        rmdir "$_mp" 2>/dev/null || true
        printf '%s' "/tmp/rootfs.tar.zst"
        return 0
      fi
      umount "$_mp" 2>/dev/null || true
    fi
    rmdir "$_mp" 2>/dev/null || true
  fi

  return 1
}

ROOTFS=$(find_rootfs || true)

# ── Validate ──────────────────────────────────────────────────────
for part in "$EFI_PART" "$ROOT_PART"; do
  if [ ! -b "$part" ]; then
    printf '{"error":"Partition not found: %s"}\n' "$part"
    exit 1
  fi
done

if [ -z "$ROOTFS" ] || [ ! -f "$ROOTFS" ]; then
  printf '{"error":"rootfs archive not found; ensure the ISO was built with --installer-ui and contains /installer/rootfs.tar.zst"}\n'
  exit 1
fi

# ── Mount root partition ──────────────────────────────────────────
mkdir -p "$TARGET"
if ! mount "$ROOT_PART" "$TARGET" 2>/dev/null; then
  printf '{"error":"Failed to mount %s on %s"}\n' "$ROOT_PART" "$TARGET"
  exit 1
fi

# ── Mount EFI partition ───────────────────────────────────────────
mkdir -p "${TARGET}/boot/efi"
if ! mount "$EFI_PART" "${TARGET}/boot/efi" 2>/dev/null; then
  umount "$TARGET" 2>/dev/null || true
  printf '{"error":"Failed to mount EFI partition %s"}\n' "$EFI_PART"
  exit 1
fi

# ── Extract rootfs ────────────────────────────────────────────────
if command -v zstd >/dev/null 2>&1; then
  # Use zstd + tar
  if ! zstd -d --stdout "$ROOTFS" | tar -xp -C "$TARGET"; then
    umount "${TARGET}/boot/efi" 2>/dev/null || true
    umount "$TARGET" 2>/dev/null || true
    printf '{"error":"Failed to extract rootfs archive"}\n'
    exit 1
  fi
elif command -v tar >/dev/null 2>&1 && tar --version 2>&1 | grep -q "GNU tar"; then
  # GNU tar with built-in zstd support
  if ! tar -xp --zstd -f "$ROOTFS" -C "$TARGET"; then
    umount "${TARGET}/boot/efi" 2>/dev/null || true
    umount "$TARGET" 2>/dev/null || true
    printf '{"error":"Failed to extract rootfs archive (GNU tar)"}\n'
    exit 1
  fi
else
  umount "${TARGET}/boot/efi" 2>/dev/null || true
  umount "$TARGET" 2>/dev/null || true
  printf '{"error":"Neither zstd nor compatible tar found for .tar.zst extraction"}\n'
  exit 1
fi

# ── Copy /etc/dayshield defaults ──────────────────────────────────
if [ -d "$DEFAULTS_DIR" ]; then
  mkdir -p "${TARGET}/etc/dayshield"
  cp -a "${DEFAULTS_DIR}/." "${TARGET}/etc/dayshield/"
fi

printf '{"ok":true}\n'
