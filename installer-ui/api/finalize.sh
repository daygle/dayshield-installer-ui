#!/bin/sh
# finalize.sh - Unmount target, sync, and clean up temporary installer files
# Query string params: disk=<name>   (e.g. disk=sda)
# Output: JSON  { "ok": true } | { "error": "message" }
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

TARGET="/mnt/target"

# ── Flush all pending writes ──────────────────────────────────────
sync

# ── Unmount bind-mounts (set up by install-bootloader.sh) ────────
for fs in dev/pts dev sys proc; do
  MP="${TARGET}/${fs}"
  if mountpoint -q "$MP" 2>/dev/null; then
    umount -l "$MP" 2>/dev/null || true
  fi
done

# ── Unmount EFI and root ──────────────────────────────────────────
EFI_MP="${TARGET}/boot/efi"
if mountpoint -q "$EFI_MP" 2>/dev/null; then
  umount "$EFI_MP" 2>/dev/null || {
    printf '{"error":"Failed to unmount EFI partition"}\n'
    exit 1
  }
fi

if mountpoint -q "$TARGET" 2>/dev/null; then
  umount "$TARGET" 2>/dev/null || {
    printf '{"error":"Failed to unmount root partition"}\n'
    exit 1
  }
fi

# ── Final sync ────────────────────────────────────────────────────
sync

# ── Clean installer temp files ────────────────────────────────────
# Remove any temp files created by the installer (not the rootfs archive)
INSTALLER_TMP="/run/installer/tmp"
if [ -d "$INSTALLER_TMP" ]; then
  rm -rf "$INSTALLER_TMP"
fi

printf '{"ok":true}\n'
