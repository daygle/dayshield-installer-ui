#!/bin/sh
# install-bootloader.sh - Install GRUB and DayShield A/B boot entries.
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
mountpoint -q "${TARGET}/boot" 2>/dev/null || json_error "Shared boot partition is not mounted at ${TARGET}/boot"

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

install_slot_boot_files() {
  slot="$1"
  source_boot="$2"
  dest="${TARGET}/boot/dayshield/slot-${slot}"
  kernel=$(find_latest_boot_file "$source_boot" "vmlinuz-" "vmlinuz") || return 1
  initrd=$(find_latest_boot_file "$source_boot" "initrd.img-" "initrd.img") || return 1
  mkdir -p "$dest"
  cp "$kernel" "${dest}/vmlinuz"
  cp "$initrd" "${dest}/initrd.img"
}

if ! find_latest_boot_file "${TARGET}/boot" "vmlinuz-" "vmlinuz" >/dev/null 2>&1; then
  chroot "$TARGET" update-initramfs -c -k all >>"$LOG" 2>&1 || true
fi

BOOT_DEV=$(blkid -L DAYSHIELD_BOOT 2>/dev/null || true)
ROOT_A_DEV=$(blkid -L DAYSHIELD_ROOT_A 2>/dev/null || true)
ROOT_B_DEV=$(blkid -L DAYSHIELD_ROOT_B 2>/dev/null || true)
[ -n "$BOOT_DEV" ] && [ -n "$ROOT_A_DEV" ] && [ -n "$ROOT_B_DEV" ] || json_error "A/B rootfs labels were not found"

BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEV" 2>/dev/null || true)
ROOT_A_UUID=$(blkid -s UUID -o value "$ROOT_A_DEV" 2>/dev/null || true)
ROOT_B_UUID=$(blkid -s UUID -o value "$ROOT_B_DEV" 2>/dev/null || true)
[ -n "$BOOT_UUID" ] && [ -n "$ROOT_A_UUID" ] && [ -n "$ROOT_B_UUID" ] || json_error "Failed to resolve A/B rootfs UUIDs"

install_slot_boot_files "a" "${TARGET}/boot" || json_error "Could not copy slot A kernel/initrd into shared boot"
mkdir -p "${TARGET}/boot/dayshield/slot-b" "${TARGET}/etc/grub.d"

cat > "${TARGET}/etc/grub.d/09_dayshield_ab" <<EOF
#!/bin/sh
set -e
cat <<'GRUB_EOF'
menuentry 'DayShield slot A' --id 'dayshield-a' {
    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
    linux /dayshield/slot-a/vmlinuz root=UUID=${ROOT_A_UUID} ro quiet splash
    initrd /dayshield/slot-a/initrd.img
}

menuentry 'DayShield slot B' --id 'dayshield-b' {
    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
    linux /dayshield/slot-b/vmlinuz root=UUID=${ROOT_B_UUID} ro quiet splash
    initrd /dayshield/slot-b/initrd.img
}
GRUB_EOF
EOF
chmod 755 "${TARGET}/etc/grub.d/09_dayshield_ab"

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

menuentry 'DayShield slot A' --id 'dayshield-a' {
    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
    linux /dayshield/slot-a/vmlinuz root=UUID=${ROOT_A_UUID} ro quiet splash
    initrd /dayshield/slot-a/initrd.img
}

menuentry 'DayShield slot B' --id 'dayshield-b' {
    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
    linux /dayshield/slot-b/vmlinuz root=UUID=${ROOT_B_UUID} ro quiet splash
    initrd /dayshield/slot-b/initrd.img
}
EOF
fi

if chroot "$TARGET" command -v grub-set-default >/dev/null 2>&1; then
  chroot "$TARGET" grub-set-default dayshield-a >>"$LOG" 2>&1 || true
elif command -v grub-editenv >/dev/null 2>&1; then
  grub-editenv "${TARGET}/boot/grub/grubenv" set saved_entry=dayshield-a >>"$LOG" 2>&1 || true
fi

json_ok "$warning"
