#!/bin/sh
# install-rootfs.sh - Mount target partitions and extract rootfs.tar.zst.
# Query string params: disk=<name> (for example: sda)

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'

REPLIED=0
ISO_SCAN_MOUNT=""

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    umount /mnt/target/boot/efi 2>/dev/null || true
    umount /mnt/target/boot 2>/dev/null || true
    umount /mnt/target 2>/dev/null || true
  fi
  if [ -n "$ISO_SCAN_MOUNT" ]; then
    umount "$ISO_SCAN_MOUNT" 2>/dev/null || true
    rmdir "$ISO_SCAN_MOUNT" 2>/dev/null || true
  fi
  if [ "$REPLIED" -eq 0 ] && [ "$status" -ne 0 ]; then
    printf '{"error":"install-rootfs failed unexpectedly"}\n'
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

reply_error() {
  REPLIED=1
  msg=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"error":"%s"}\n' "$msg"
  exit 1
}

reply_ok() {
  REPLIED=1
  printf '{"ok":true}\n'
  exit 0
}

decode_urlencoded() {
  local s="$1" out="" hex
  while [ -n "$s" ]; do
    case "$s" in
      +*) out="${out} "; s="${s#?}" ;;
      %??*) hex="${s#%}"; hex="${hex%${hex#??}}"; s="${s#%??}"; out="${out}$(printf '\\x%s' "$hex")" ;;
      *) out="${out}${s%${s#?}}"; s="${s#?}" ;;
    esac
  done
  printf '%s' "$out"
}

query_param() {
  printf '%s' "$1" | tr '&' '\n' | sed -n "s/^$2=//p" | head -n1
}

part_node() {
  case "$DISK" in
    nvme*|mmcblk*) printf '/dev/%sp%s' "$DISK" "$1" ;;
    *) printf '/dev/%s%s' "$DISK" "$1" ;;
  esac
}

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

  _dev=$(blkid -t LABEL=DAYSHIELD -o device 2>/dev/null | head -n1 || true)
  if [ -n "$_dev" ]; then
    _mp=$(mktemp -d)
    if mount -o ro "$_dev" "$_mp" 2>/dev/null; then
      if [ -f "${_mp}/installer/rootfs.tar.zst" ]; then
        ISO_SCAN_MOUNT="$_mp"
        printf '%s' "${_mp}/installer/rootfs.tar.zst"
        return 0
      fi
      umount "$_mp" 2>/dev/null || true
    fi
    rmdir "$_mp" 2>/dev/null || true
  fi

  return 1
}

extract_rootfs() {
  archive="$1"
  target="$2"
  if command -v zstd >/dev/null 2>&1; then
    zstd -d --stdout "$archive" | tar -xp -C "$target"
  elif command -v tar >/dev/null 2>&1 && tar --version 2>&1 | grep -q "GNU tar"; then
    tar -xp --zstd -f "$archive" -C "$target"
  else
    return 2
  fi
}

DISK=""
if [ -n "${QUERY_STRING:-}" ]; then
  DISK=$(decode_urlencoded "$(query_param "$QUERY_STRING" disk)")
fi
[ -n "$DISK" ] || reply_error "Missing required parameter: disk"
DISK=$(printf '%s' "$DISK" | sed 's|^/dev/||')
printf '%s' "$DISK" | grep -Eq '^[a-zA-Z0-9]+$' || reply_error "Invalid disk name"

EFI_PART=$(part_node 2)
BOOT_PART=$(part_node 3)
ROOT_PART=$(part_node 4)
for part in "$EFI_PART" "$BOOT_PART" "$ROOT_PART"; do
  [ -b "$part" ] || reply_error "Partition not found: $part"
done

ROOTFS=$(find_rootfs || true)
[ -n "$ROOTFS" ] && [ -f "$ROOTFS" ] || reply_error "rootfs archive not found; ensure the ISO contains /installer/rootfs.tar.zst"

TARGET="/mnt/target"
mkdir -p "$TARGET"
mount "$ROOT_PART" "$TARGET" 2>/dev/null || reply_error "Failed to mount $ROOT_PART on $TARGET"
mkdir -p "$TARGET/boot"
mount "$BOOT_PART" "$TARGET/boot" 2>/dev/null || reply_error "Failed to mount boot partition $BOOT_PART"
mkdir -p "$TARGET/boot/efi"
mount "$EFI_PART" "$TARGET/boot/efi" 2>/dev/null || reply_error "Failed to mount EFI partition $EFI_PART"

extract_rootfs "$ROOTFS" "$TARGET" >/tmp/dayshield-install-rootfs.log 2>&1 || reply_error "Failed to extract rootfs archive"

DEFAULTS_DIR="/run/installer/defaults"
if [ -d "$DEFAULTS_DIR" ]; then
  mkdir -p "${TARGET}/etc/dayshield"
  cp -a "${DEFAULTS_DIR}/." "${TARGET}/etc/dayshield/"
fi

reply_ok
