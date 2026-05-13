#!/bin/sh
# finalize.sh - Unmount target, sync, and clean up temporary installer files
# Query string params: disk=<name>   (e.g. disk=sda)
# Output: JSON  { "ok": true } | { "error": "message" }
#
# Must be POSIX-compliant and run as root.

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'

decode_urlencoded() {
  local s="$1"
  local out=""
  local hex

  while [ -n "$s" ]; do
    case "$s" in
      +*)
        out="${out} "
        s="${s#?}"
        ;;
      %??*)
        hex="${s#%}"
        hex="${hex%${hex#??}}"
        s="${s#%??}"
        out="${out}$(printf '\\x%s' "$hex")"
        ;;
      *)
        out="${out}${s%${s#?}}"
        s="${s#?}"
        ;;
    esac
  done
  printf '%s' "$out"
}

extract_query_param() {
  printf '%s' "$1" | sed 's/.*disk=\([^&]*\).*/\1/'
}

# ── Parse CGI query string ────────────────────────────────────────
DISK=""
if [ -n "${QUERY_STRING:-}" ]; then
  DISK=$(extract_query_param "$QUERY_STRING")
  DISK=$(decode_urlencoded "$DISK")
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

TARGET="/mnt/target"

# ── Enable firstboot service ──────────────────────────────────────
# firstboot.service runs once on the first post-install boot to perform
# final system setup (SSH host key generation, etc.) and then disables itself.
SYSTEMD_MULTI_USER="${TARGET}/etc/systemd/system/multi-user.target.wants"
if [ -f "${TARGET}/etc/systemd/system/firstboot.service" ]; then
  mkdir -p "$SYSTEMD_MULTI_USER"
  ln -sf "/etc/systemd/system/firstboot.service" \
     "${SYSTEMD_MULTI_USER}/firstboot.service" 2>/dev/null || true
elif [ -f "${TARGET}/usr/lib/systemd/system/firstboot.service" ]; then
  mkdir -p "$SYSTEMD_MULTI_USER"
  ln -sf "/usr/lib/systemd/system/firstboot.service" \
     "${SYSTEMD_MULTI_USER}/firstboot.service" 2>/dev/null || true
fi

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
