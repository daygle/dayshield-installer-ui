#!/bin/sh
# install-bootloader.sh - Install GRUB for both BIOS (MBR) and UEFI targets
# Query string params: disk=<name>   (e.g. disk=sda)
# Output: JSON  { "ok": true } | { "error": "message" }
#
# Assumes install-rootfs.sh has already run and /mnt/target is mounted.
# Installs:
#   - grub-install --target=i386-pc       (BIOS/CSM)
#   - grub-install --target=x86_64-efi    (UEFI)
#   - grub-mkconfig  →  /boot/grub/grub.cfg
#
# Must be POSIX-compliant and run as root.

set -eu

# CGI shells may have a minimal PATH that excludes sbin where GRUB tools live.
PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

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
DEV="/dev/${DISK}"
TARGET="/mnt/target"

# ── Validate ──────────────────────────────────────────────────────
if [ ! -b "$DEV" ]; then
  printf '{"error":"Device not found: %s"}\n' "$DEV"
  exit 1
fi

if [ ! -d "${TARGET}/etc" ]; then
  printf '{"error":"Target root not found at %s - run install-rootfs first"}\n' "$TARGET"
  exit 1
fi

HOST_GRUB_INSTALL=""
if command -v grub-install >/dev/null 2>&1; then
  HOST_GRUB_INSTALL=$(command -v grub-install)
fi

TARGET_GRUB_INSTALL=""
if [ -x "${TARGET}/usr/sbin/grub-install" ]; then
  TARGET_GRUB_INSTALL="/usr/sbin/grub-install"
elif [ -x "${TARGET}/usr/bin/grub-install" ]; then
  TARGET_GRUB_INSTALL="/usr/bin/grub-install"
fi

if [ -z "${HOST_GRUB_INSTALL}" ] && [ -z "${TARGET_GRUB_INSTALL}" ]; then
  printf '{"error":"grub-install not found on live system or target rootfs"}\n'
  exit 1
fi

# ── Bind-mount pseudo-filesystems for chroot ─────────────────────
for fs in proc sys dev dev/pts run; do
  mkdir -p "${TARGET}/${fs}"
  mount --bind "/${fs}" "${TARGET}/${fs}" >/dev/null 2>&1 || true
done

cleanup() {
  for fs in run dev/pts dev sys proc; do
    umount "${TARGET}/${fs}" 2>/dev/null || true
  done
}
trap cleanup EXIT

BOOT_OK=0
WARNING_MSG=""

# ── Install GRUB - BIOS (i386-pc) ────────────────────────────────
if [ -d "${TARGET}/usr/lib/grub/i386-pc" ] || \
   [ -d "/usr/lib/grub/i386-pc" ]; then
  if [ -n "${HOST_GRUB_INSTALL}" ]; then
    if ! "${HOST_GRUB_INSTALL}" \
          --target=i386-pc \
          --boot-directory="${TARGET}/boot" \
          --recheck \
          "$DEV" >/dev/null 2>&1; then
      WARNING_MSG="BIOS grub-install failed on ${DEV}"
    else
      BOOT_OK=1
    fi
  elif [ -n "${TARGET_GRUB_INSTALL}" ]; then
    if ! chroot "$TARGET" "${TARGET_GRUB_INSTALL}" \
          --target=i386-pc \
          --boot-directory=/boot \
          --recheck \
          "$DEV" >/dev/null 2>&1; then
      WARNING_MSG="BIOS grub-install failed in target on ${DEV}"
    else
      BOOT_OK=1
    fi
  else
    WARNING_MSG="BIOS grub-install unavailable for ${DEV}"
  fi
fi

# ── Install GRUB - UEFI (x86_64-efi) ────────────────────────────
EFI_DIR="${TARGET}/boot/efi"
if [ -d "${TARGET}/usr/lib/grub/x86_64-efi" ] || \
   [ -d "/usr/lib/grub/x86_64-efi" ]; then
  if [ -n "${HOST_GRUB_INSTALL}" ]; then
    if ! "${HOST_GRUB_INSTALL}" \
          --target=x86_64-efi \
          --efi-directory="$EFI_DIR" \
          --boot-directory="${TARGET}/boot" \
          --bootloader-id="DayShield" \
          --removable \
          --no-nvram \
          --recheck \
          >/dev/null 2>&1; then
      if [ -n "${WARNING_MSG}" ]; then
        WARNING_MSG="${WARNING_MSG}; UEFI grub-install failed"
      else
        WARNING_MSG="UEFI grub-install failed"
      fi
    else
      BOOT_OK=1
    fi
  elif [ -n "${TARGET_GRUB_INSTALL}" ]; then
    if ! chroot "$TARGET" "${TARGET_GRUB_INSTALL}" \
          --target=x86_64-efi \
          --efi-directory=/boot/efi \
          --boot-directory=/boot \
          --bootloader-id="DayShield" \
          --removable \
          --no-nvram \
          --recheck \
          >/dev/null 2>&1; then
      if [ -n "${WARNING_MSG}" ]; then
        WARNING_MSG="${WARNING_MSG}; UEFI grub-install failed in target"
      else
        WARNING_MSG="UEFI grub-install failed in target"
      fi
    else
      BOOT_OK=1
    fi
  else
    if [ -n "${WARNING_MSG}" ]; then
      WARNING_MSG="${WARNING_MSG}; UEFI grub-install unavailable"
    else
      WARNING_MSG="UEFI grub-install unavailable"
    fi
  fi
fi

if [ "${BOOT_OK}" -ne 1 ]; then
  if [ -n "${WARNING_MSG}" ]; then
    printf '{"error":"%s"}\n' "${WARNING_MSG}"
  else
    printf '{"error":"No bootloader target was installable"}\n'
  fi
  exit 1
fi

# ── Ensure kernel and initramfs exist ───────────────────────────
# If the rootfs extraction didn't include these files, generate them now
KERNEL_PRESENT=0
if [ -f "${TARGET}/boot/vmlinuz" ]; then
  KERNEL_PRESENT=1
else
  for _k in "${TARGET}"/boot/vmlinuz-*; do
    if [ -e "$_k" ]; then
      KERNEL_PRESENT=1
      break
    fi
  done
fi
if [ "$KERNEL_PRESENT" -ne 1 ]; then
  WARNING_MSG="${WARNING_MSG:+$WARNING_MSG; }Kernel not found in /boot, attempting to generate initramfs"
  
  # Try update-initramfs in chroot (Debian/Ubuntu)
  if chroot "$TARGET" update-initramfs -c -k all >/dev/null 2>&1; then
    : # Successfully generated
  else
    # Try dracut as fallback (if available)
    if command -v dracut >/dev/null 2>&1; then
      dracut -r "$TARGET" --force /boot/initrd.img >/dev/null 2>&1 || true
    fi
  fi
fi

# ── Generate grub.cfg ─────────────────────────────────────────────
# Prefer chroot grub-mkconfig; fall back to host grub-mkconfig
GRUB_CFG="${TARGET}/boot/grub/grub.cfg"
mkdir -p "${TARGET}/boot/grub"

if [ -x "${TARGET}/usr/sbin/grub-mkconfig" ] || \
   [ -x "${TARGET}/usr/bin/grub-mkconfig" ]; then
  chroot "$TARGET" grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
elif command -v grub-mkconfig >/dev/null 2>&1; then
  GRUB_DEVICE="$DEV" \
  GRUB_DEVICE_BOOT="$DEV" \
  grub-mkconfig -o "$GRUB_CFG" >/dev/null 2>&1 || true
fi

# ── Write minimal fallback grub.cfg if missing ───────────────────
if [ ! -s "$GRUB_CFG" ]; then
  ROOT_NODE="/dev/${DISK}3"
  case "$DISK" in
    nvme*|mmcblk*) ROOT_NODE="/dev/${DISK}p3" ;;
  esac
  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_NODE" 2>/dev/null || true)
  
  # Check for actual kernel/initrd files and report findings
  KERNEL_FILE=""
  INITRD_FILE=""
  if [ -f "${TARGET}/boot/vmlinuz" ]; then
    KERNEL_FILE="/boot/vmlinuz"
  elif ls "${TARGET}/boot/vmlinuz-"* >/dev/null 2>&1; then
    KERNEL_FILE=$(ls -1 "${TARGET}/boot/vmlinuz-"* | head -n1 | xargs basename)
  fi
  if ls "${TARGET}/boot/initrd.img"* >/dev/null 2>&1; then
    INITRD_FILE=$(ls -1 "${TARGET}/boot/initrd.img"* | head -n1 | xargs basename)
  fi
  
  if [ -z "$KERNEL_FILE" ] || [ -z "$INITRD_FILE" ]; then
    WARNING_MSG="${WARNING_MSG:+$WARNING_MSG; }Missing kernel/initrd: kernel=$KERNEL_FILE initrd=$INITRD_FILE"
  fi
  
  KERNEL_ENTRY="${KERNEL_FILE:-vmlinuz}"
  INITRD_ENTRY="${INITRD_FILE:-initrd.img}"

  cat > "$GRUB_CFG" << GRUBCFG
set default=0
set timeout=5

menuentry "DayShield Firewall OS" {
  search --no-floppy --label --set=root dayshield-root
  linux  /boot/${KERNEL_ENTRY} root=LABEL=dayshield-root rw quiet ipv6.disable=1
  initrd /boot/${INITRD_ENTRY}
}
GRUBCFG
  if [ -n "$ROOT_UUID" ]; then
    # Replace label with UUID for more reliable boot
    sed -i "s|LABEL=dayshield-root|UUID=${ROOT_UUID}|g" "$GRUB_CFG"
  fi
fi

if [ -n "${WARNING_MSG}" ]; then
  WARNING_JSON=$(printf '%s' "${WARNING_MSG}" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"ok":true,"warning":"%s"}\n' "${WARNING_JSON}"
else
  printf '{"ok":true}\n'
fi
