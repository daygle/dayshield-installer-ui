#!/bin/sh
# finalize.sh - Unmount target, sync, and clean up temporary installer files
# Query string params: disk=<name>   (e.g. disk=sda)
# Output: JSON  { "ok": true } | { "error": "message" }
#
# Must be POSIX-compliant and run as root.

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

if [ ! -d "${TARGET}/etc" ]; then
  json_error "Target root not found at ${TARGET} - run install-rootfs first"
fi

FIRSTBOOT_SRC_DIR="/usr/lib/dayshield-installer"
FIRSTBOOT_RUN_SRC="${FIRSTBOOT_SRC_DIR}/firstboot-run.sh"
FIRSTBOOT_SERVICE_SRC="${FIRSTBOOT_SRC_DIR}/firstboot.service"
[ -f "$FIRSTBOOT_RUN_SRC" ] || json_error "Missing firstboot-run.sh in live installer"
[ -f "$FIRSTBOOT_SERVICE_SRC" ] || json_error "Missing firstboot.service in live installer"

mkdir -p "${TARGET}/usr/lib/dayshield-installer" "${TARGET}/etc/systemd/system" "${TARGET}/etc/dayshield"
if ! install -m 755 "$FIRSTBOOT_RUN_SRC" "${TARGET}/usr/lib/dayshield-installer/firstboot-run.sh" 2>/dev/null; then
  cp "$FIRSTBOOT_RUN_SRC" "${TARGET}/usr/lib/dayshield-installer/firstboot-run.sh"
  chmod 755 "${TARGET}/usr/lib/dayshield-installer/firstboot-run.sh"
fi
if ! install -m 644 "$FIRSTBOOT_SERVICE_SRC" "${TARGET}/etc/systemd/system/firstboot.service" 2>/dev/null; then
  cp "$FIRSTBOOT_SERVICE_SRC" "${TARGET}/etc/systemd/system/firstboot.service"
  chmod 644 "${TARGET}/etc/systemd/system/firstboot.service"
fi
touch "${TARGET}/etc/dayshield/.firstboot"

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

BOOT_MP="${TARGET}/boot"
if mountpoint -q "$BOOT_MP" 2>/dev/null; then
  umount "$BOOT_MP" 2>/dev/null || {
    printf '{"error":"Failed to unmount boot partition"}\n'
    exit 1
  }
fi

VAR_MP="${TARGET}/var"
if mountpoint -q "$VAR_MP" 2>/dev/null; then
  umount "$VAR_MP" 2>/dev/null || {
    printf '{"error":"Failed to unmount state partition"}\n'
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
