#!/bin/sh
# install-bootloader.sh - Install GRUB for the DayShield OSTree system layout.
# Query string params: disk=<name> (for example: sda)

set -eu

PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

printf 'Content-Type: application/json\r\n'
printf '\r\n'

LOG="/tmp/dayshield-install-bootloader.log"
: > "$LOG" 2>/dev/null || true

json_error() {
  msg=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"error":"%s"}\n' "$msg"
  exit 1
}

json_ok() {
  if [ -n "${1:-}" ]; then
    msg=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"ok":true,"warning":"%s"}\n' "$msg"
  else
    printf '{"ok":true}\n'
  fi
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

find_latest_boot_file() {
  dir="$1"
  prefix="$2"
  exact="$3"
  if [ -e "${dir}/${exact}" ]; then
    printf '%s' "${dir}/${exact}"
    return 0
  fi
  candidate=$(find "$dir" -maxdepth 1 -name "${prefix}*" 2>/dev/null | sort | tail -n1)
  [ -n "$candidate" ] || return 1
  printf '%s' "$candidate"
}

DISK=""
if [ -n "${QUERY_STRING:-}" ]; then
  DISK=$(decode_urlencoded "$(query_param "$QUERY_STRING" disk)")
fi
[ -n "$DISK" ] || json_error "Missing required parameter: disk"
DISK=$(printf '%s' "$DISK" | sed 's|^/dev/||')
printf '%s' "$DISK" | grep -Eq '^[a-zA-Z0-9]+$' || json_error "Invalid disk name"

DEV="/dev/${DISK}"
TARGET="/mnt/target"
[ -b "$DEV" ] || json_error "Device not found: $DEV"
[ -d "${TARGET}/etc" ] || json_error "Target root not found at $TARGET - run install-rootfs first"
mountpoint -q "${TARGET}/boot" 2>/dev/null || json_error "Boot partition is not mounted at ${TARGET}/boot"

cleanup() {
  for fs in run dev/pts dev sys proc; do
    umount "${TARGET}/${fs}" 2>/dev/null || true
  done
}
trap cleanup EXIT HUP INT TERM

for fs in proc sys dev dev/pts run; do
  mkdir -p "${TARGET}/${fs}"
  mount --bind "/${fs}" "${TARGET}/${fs}" >/dev/null 2>&1 || true
done

warning=""
boot_ok=0

if [ -d "${TARGET}/usr/lib/grub/i386-pc" ] || [ -d "/usr/lib/grub/i386-pc" ]; then
  if command -v grub-install >/dev/null 2>&1; then
    if grub-install --target=i386-pc --boot-directory="${TARGET}/boot" --recheck "$DEV" >>"$LOG" 2>&1; then
      boot_ok=1
    else
      warning="BIOS grub-install failed on ${DEV}"
    fi
  elif chroot "$TARGET" command -v grub-install >/dev/null 2>&1; then
    if chroot "$TARGET" grub-install --target=i386-pc --boot-directory=/boot --recheck "$DEV" >>"$LOG" 2>&1; then
      boot_ok=1
    else
      warning="BIOS grub-install failed in target on ${DEV}"
    fi
  fi
fi

if [ -d "${TARGET}/usr/lib/grub/x86_64-efi" ] || [ -d "/usr/lib/grub/x86_64-efi" ]; then
  if command -v grub-install >/dev/null 2>&1; then
    if grub-install --target=x86_64-efi --efi-directory="${TARGET}/boot/efi" --boot-directory="${TARGET}/boot" --bootloader-id="DayShield" --removable --no-nvram --recheck >>"$LOG" 2>&1; then
      boot_ok=1
    else
      warning="${warning:+$warning; }UEFI grub-install failed"
    fi
  elif chroot "$TARGET" command -v grub-install >/dev/null 2>&1; then
    if chroot "$TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --bootloader-id="DayShield" --removable --no-nvram --recheck >>"$LOG" 2>&1; then
      boot_ok=1
    else
      warning="${warning:+$warning; }UEFI grub-install failed in target"
    fi
  fi
fi

[ "$boot_ok" -eq 1 ] || json_error "${warning:-No bootloader target was installable}"

if [ -f "${TARGET}/boot/efi/EFI/DayShield/grubx64.efi" ]; then
  mkdir -p "${TARGET}/boot/efi/EFI/BOOT"
  cp "${TARGET}/boot/efi/EFI/DayShield/grubx64.efi" "${TARGET}/boot/efi/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || true
elif [ -f "${TARGET}/boot/efi/EFI/dayshield/grubx64.efi" ]; then
  mkdir -p "${TARGET}/boot/efi/EFI/BOOT"
  cp "${TARGET}/boot/efi/EFI/dayshield/grubx64.efi" "${TARGET}/boot/efi/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || true
fi

BOOT_DEV=$(blkid -L DAYSHIELD_BOOT 2>/dev/null || true)
ROOT_DEV=$(blkid -L DAYSHIELD_SYSROOT 2>/dev/null || true)
[ -n "$BOOT_DEV" ] && [ -n "$ROOT_DEV" ] || json_error "Required boot/sysroot labels were not found"

BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEV" 2>/dev/null || true)
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)
[ -n "$BOOT_UUID" ] && [ -n "$ROOT_UUID" ] || json_error "Failed to resolve boot/sysroot UUIDs"

KERNEL_FILE=$(find_latest_boot_file "${TARGET}/boot" "vmlinuz-" "vmlinuz") || json_error "Could not find kernel in ${TARGET}/boot"
INITRD_FILE=$(find_latest_boot_file "${TARGET}/boot" "initrd.img-" "initrd.img") || json_error "Could not find initrd in ${TARGET}/boot"
KERNEL_NAME=$(basename "$KERNEL_FILE")
INITRD_NAME=$(basename "$INITRD_FILE")

mkdir -p "${TARGET}/etc/grub.d"
cat > "${TARGET}/etc/grub.d/09_dayshield_ostree" <<EOF
#!/bin/sh
set -e
cat <<'GRUB_EOF'
menuentry 'DayShield System' --id 'dayshield' {
    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
    linux /${KERNEL_NAME} root=UUID=${ROOT_UUID} ro quiet splash
    initrd /${INITRD_NAME}
}
GRUB_EOF
EOF
chmod 755 "${TARGET}/etc/grub.d/09_dayshield_ostree"

cat > "${TARGET}/etc/default/grub" <<'EOF'
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=false
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="DayShield"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL_INPUT=console
GRUB_GFXMODE=auto
EOF

mkdir -p "${TARGET}/boot/grub"
if chroot "$TARGET" command -v grub-mkconfig >/dev/null 2>&1; then
  chroot "$TARGET" grub-mkconfig -o /boot/grub/grub.cfg >>"$LOG" 2>&1 || true
elif command -v grub-mkconfig >/dev/null 2>&1; then
  grub-mkconfig -o "${TARGET}/boot/grub/grub.cfg" >>"$LOG" 2>&1 || true
fi

if [ ! -s "${TARGET}/boot/grub/grub.cfg" ]; then
  cat > "${TARGET}/boot/grub/grub.cfg" <<EOF
set default=saved
set timeout=5

menuentry 'DayShield System' --id 'dayshield' {
    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
    linux /${KERNEL_NAME} root=UUID=${ROOT_UUID} ro quiet splash
    initrd /${INITRD_NAME}
}
EOF
fi

if chroot "$TARGET" command -v grub-set-default >/dev/null 2>&1; then
  chroot "$TARGET" grub-set-default dayshield >>"$LOG" 2>&1 || true
elif command -v grub-editenv >/dev/null 2>&1; then
  grub-editenv "${TARGET}/boot/grub/grubenv" set saved_entry=dayshield >>"$LOG" 2>&1 || true
fi

json_ok "$warning"
