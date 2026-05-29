#!/bin/sh
# install-rootfs.sh - Mount target partitions and extract rootfs for the
# image-based update layout (single root, no A/B).
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
    umount /mnt/target/var 2>/dev/null || true
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
STATE_PART=$(part_node 5)
for part in "$EFI_PART" "$BOOT_PART" "$ROOT_PART" "$STATE_PART"; do
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
mkdir -p "$TARGET/var"
mount "$STATE_PART" "$TARGET/var" 2>/dev/null || reply_error "Failed to mount persistent state partition $STATE_PART"

extract_rootfs "$ROOTFS" "$TARGET" >/tmp/dayshield-install-rootfs.log 2>&1 || reply_error "Failed to extract rootfs archive"

DEFAULTS_DIR="/run/installer/defaults"
if [ -d "$DEFAULTS_DIR" ]; then
  mkdir -p "${TARGET}/etc/dayshield"
  cp -a "${DEFAULTS_DIR}/." "${TARGET}/etc/dayshield/"
fi

# Resolve the installed version from the build-stamped version file rather
# than writing a placeholder — this is what dayshield-core's status() falls
# back to when current.json is absent, but writing it explicitly keeps the
# rollback / boot-success flow consistent from the first boot.
INSTALL_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || printf 'unknown')
INSTALLED_VERSION=$(tr -d '[:space:]' < "${TARGET}/etc/dayshield/version" 2>/dev/null || true)
[ -n "$INSTALLED_VERSION" ] || INSTALLED_VERSION="unknown"

ROOTFS_STATE_DIR="${TARGET}/var/lib/dayshield/rootfs-update"
mkdir -p "$ROOTFS_STATE_DIR"
printf '{"version":"%s","recordedAt":"%s"}\n' "$INSTALLED_VERSION" "$INSTALL_TS" > "${ROOTFS_STATE_DIR}/current.json"

# Seed /boot/dayshield/images with the installed squashfs so the in-place
# image-based update flow has a known-good baseline.  This makes "rollback to
# previous version" work even immediately after a fresh install (it rolls back
# to the install version itself) and gives the auto-revert path something to
# target if a future update breaks the kernel/userspace.
IMAGE_STORE="${TARGET}/boot/dayshield/images"
mkdir -p "$IMAGE_STORE" "${TARGET}/boot/dayshield/metadata"

# Look for the clean squashfs the ISO build embeds at /installer/rootfs.squashfs.
# (assemble-iso.sh writes it there from the rootfs release artifact.)
SQUASHFS_SRC=""
for candidate in \
  "$(dirname "$ROOTFS")/rootfs.squashfs" \
  "$(dirname "$ROOTFS")/rootfs-${INSTALLED_VERSION}.squashfs"; do
  if [ -f "$candidate" ]; then
    SQUASHFS_SRC="$candidate"
    break
  fi
done

if [ -n "$SQUASHFS_SRC" ] && [ "$INSTALLED_VERSION" != "unknown" ]; then
  DEST_IMAGE="${IMAGE_STORE}/rootfs-${INSTALLED_VERSION}.squashfs"
  cp -f "$SQUASHFS_SRC" "$DEST_IMAGE"
  chmod 644 "$DEST_IMAGE"
  if command -v sha256sum >/dev/null 2>&1; then
    sha=$(sha256sum "$DEST_IMAGE" | awk '{print $1}')
    printf '%s  %s\n' "$sha" "$(basename "$DEST_IMAGE")" > "${DEST_IMAGE}.sha256"
    chmod 644 "${DEST_IMAGE}.sha256"
  fi
  ln -sfn "images/rootfs-${INSTALLED_VERSION}.squashfs" "${TARGET}/boot/dayshield/current"
fi

# Initialise the boot-attempt counter so the auto-revert logic starts clean.
printf '0\n' > "${TARGET}/boot/dayshield/boot-attempts"

reply_ok
