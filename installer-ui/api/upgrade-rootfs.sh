#!/bin/sh
# upgrade-rootfs.sh - Stage an ISO rootfs into the inactive DayShield Primary/Secondary slot.
# Query string params: disk=<name> (for example: sda)

set -eu

PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

printf 'Content-Type: application/json\r\n'
printf '\r\n'

LOG="/tmp/dayshield-iso-upgrade.log"
: > "$LOG" 2>/dev/null || true

REPLIED=0
ISO_SCAN_MOUNT=""
ACTIVE_MOUNT=""
BOOT_MOUNT=""
TARGET="/mnt/target"

cleanup() {
  status=$?
  for fs in run dev/pts dev sys proc; do
    umount "${TARGET}/${fs}" 2>/dev/null || true
  done
  umount "${TARGET}/boot/efi" 2>/dev/null || true
  umount "${TARGET}/boot" 2>/dev/null || true
  [ -n "$BOOT_MOUNT" ] && umount "$BOOT_MOUNT" 2>/dev/null || true
  umount "$TARGET" 2>/dev/null || true
  [ -n "$ACTIVE_MOUNT" ] && umount "$ACTIVE_MOUNT" 2>/dev/null || true
  [ -n "$ISO_SCAN_MOUNT" ] && umount "$ISO_SCAN_MOUNT" 2>/dev/null || true
  [ -n "$ISO_SCAN_MOUNT" ] && rmdir "$ISO_SCAN_MOUNT" 2>/dev/null || true
  [ -n "$ACTIVE_MOUNT" ] && rmdir "$ACTIVE_MOUNT" 2>/dev/null || true
  [ -n "$BOOT_MOUNT" ] && rmdir "$BOOT_MOUNT" 2>/dev/null || true
  if [ "$REPLIED" -eq 0 ] && [ "$status" -ne 0 ]; then
    printf '{"error":"upgrade-rootfs failed unexpectedly"}\n'
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
  printf '{"ok":true,"previous_slot":"%s","target_slot":"%s"}\n' "$1" "$2"
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

device_parent_disk() {
  dev="$1"
  pkname=$(lsblk -ndo PKNAME "$dev" 2>/dev/null || true)
  if [ -n "$pkname" ]; then
    printf '/dev/%s' "$pkname"
  else
    printf '%s' "$dev" | sed -E 's/p?[0-9]+$//'
  fi
}

require_on_target_disk() {
  dev="$1"
  parent=$(device_parent_disk "$dev")
  [ "$parent" = "$TARGET_DISK" ] || reply_error "$dev does not belong to selected disk $TARGET_DISK"
}

uuid_of() {
  blkid -s UUID -o value "$1" 2>/dev/null || true
}

label_device() {
  blkid -L "$1" 2>/dev/null || true
}

root_slot_device() {
  dev=$(label_device "$1")
  [ -n "$dev" ] || dev=$(label_device "$2")
  printf '%s' "$dev"
}

read_default_slot() {
  grubenv="${BOOT_MOUNT}/grub/grubenv"
  if [ -f "$grubenv" ]; then
    slot=$(sed -n 's/^saved_entry=dayshield-\([ab]\)$/\1/p' "$grubenv" | tail -n1)
    [ -n "$slot" ] && { printf '%s' "$slot"; return 0; }
  fi
  printf 'a'
}

copy_persistent_path() {
  rel="${1#/}"
  [ -e "${ACTIVE_MOUNT}/${rel}" ] || return 0
  rm -rf "${TARGET:?}/${rel}"
  parent=$(dirname "${TARGET}/${rel}")
  mkdir -p "$parent"
  cp -a "${ACTIVE_MOUNT}/${rel}" "$parent/"
}

copy_persistent_state() {
  for path in \
    /etc/dayshield \
    /etc/wireguard \
    /etc/cloudflared \
    /etc/hostname \
    /etc/hosts \
    /etc/machine-id \
    /etc/ssh \
    /etc/systemd/network \
    /var/lib/dayshield \
    /var/lib/cloudflared
  do
    copy_persistent_path "$path"
  done
  rm -rf "${TARGET}/var/lib/dayshield/update-staging" "${TARGET}/var/lib/dayshield/update/rootfs-slot"
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

install_slot_boot_files() {
  slot="$1"
  source_boot="$2"
  dest="${BOOT_MOUNT}/dayshield/slot-${slot}"
  kernel=$(find_latest_boot_file "$source_boot" "vmlinuz-" "vmlinuz") || return 1
  initrd=$(find_latest_boot_file "$source_boot" "initrd.img-" "initrd.img") || return 1
  mkdir -p "$dest"
  cp "$kernel" "${dest}/vmlinuz"
  cp "$initrd" "${dest}/initrd.img"
}

ensure_active_boot_files() {
  slot="$1"
  if [ -f "${BOOT_MOUNT}/dayshield/slot-${slot}/vmlinuz" ] && [ -f "${BOOT_MOUNT}/dayshield/slot-${slot}/initrd.img" ]; then
    return 0
  fi
  install_slot_boot_files "$slot" "$BOOT_MOUNT" || true
}

write_fstab() {
  root_uuid=$(uuid_of "$INACTIVE_DEV")
  boot_uuid=$(uuid_of "$BOOT_DEV")
  efi_uuid=$(uuid_of "$EFI_DEV")
  [ -n "$root_uuid" ] && [ -n "$boot_uuid" ] || reply_error "Failed to resolve root/boot UUIDs after formatting"
  {
    cat <<EOF
# /etc/fstab - generated by DayShield ISO rootfs upgrade
UUID=${root_uuid}  /          ext4  defaults,noatime  0  1
UUID=${boot_uuid}  /boot      ext4  defaults,noatime  0  2
EOF
    if [ -n "$efi_uuid" ]; then
      printf 'UUID=%s   /boot/efi  vfat  umask=0077        0  2\n' "$efi_uuid"
    else
      printf '%s   /boot/efi  vfat  umask=0077        0  2\n' "$EFI_DEV"
    fi
    printf 'tmpfs              /tmp       tmpfs defaults           0  0\n'
  } > "${TARGET}/etc/fstab"
}

write_iso_marker() {
  mkdir -p "${TARGET}/etc/dayshield/config"
  prepared_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "${TARGET}/etc/dayshield/config/rootfs-iso-upgrade.json" <<EOF
{
  "status": "staged",
  "targetSlot": "${INACTIVE_SLOT}",
  "previousSlot": "${ACTIVE_SLOT}",
  "targetVersion": "iso",
  "preparedAt": "${prepared_at}",
  "bootedAt": null,
  "confirmedAt": null,
  "lastError": null
}
EOF
}

write_grub_config() {
  boot_uuid=$(uuid_of "$BOOT_DEV")
  root_a_uuid=$(uuid_of "$ROOT_A_DEV")
  root_b_uuid=$(uuid_of "$ROOT_B_DEV")
  [ -n "$boot_uuid" ] && [ -n "$root_a_uuid" ] && [ -n "$root_b_uuid" ] || reply_error "Failed to resolve Primary/Secondary rootfs UUIDs"
  mkdir -p "${TARGET}/etc/grub.d" "${TARGET}/boot/grub"
  cat > "${TARGET}/etc/grub.d/09_dayshield_ab" <<EOF
#!/bin/sh
set -e
cat <<'GRUB_EOF'
menuentry 'DayShield Primary System' --id 'dayshield-a' {
    search --no-floppy --fs-uuid --set=root ${boot_uuid}
    linux /dayshield/slot-a/vmlinuz root=UUID=${root_a_uuid} ro quiet splash
    initrd /dayshield/slot-a/initrd.img
}

menuentry 'DayShield Secondary System' --id 'dayshield-b' {
    search --no-floppy --fs-uuid --set=root ${boot_uuid}
    linux /dayshield/slot-b/vmlinuz root=UUID=${root_b_uuid} ro quiet splash
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
}

schedule_trial_boot() {
  if chroot "$TARGET" command -v grub-mkconfig >/dev/null 2>&1; then
    chroot "$TARGET" grub-mkconfig -o /boot/grub/grub.cfg >>"$LOG" 2>&1 || reply_error "grub-mkconfig failed"
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o "${TARGET}/boot/grub/grub.cfg" >>"$LOG" 2>&1 || reply_error "grub-mkconfig failed"
  else
    reply_error "grub-mkconfig not found"
  fi

  entry="dayshield-${INACTIVE_SLOT}"
  if chroot "$TARGET" command -v grub-reboot >/dev/null 2>&1; then
    chroot "$TARGET" grub-reboot "$entry" >>"$LOG" 2>&1 || reply_error "grub-reboot failed"
  elif command -v grub-editenv >/dev/null 2>&1; then
    grub-editenv "${TARGET}/boot/grub/grubenv" set next_entry="$entry" >>"$LOG" 2>&1 || reply_error "grub-editenv failed"
  else
    reply_error "grub-reboot/grub-editenv not found"
  fi
}

DISK=""
if [ -n "${QUERY_STRING:-}" ]; then
  DISK=$(decode_urlencoded "$(query_param "$QUERY_STRING" disk)")
fi
[ -n "$DISK" ] || reply_error "Missing required parameter: disk"
DISK=$(printf '%s' "$DISK" | sed 's|^/dev/||')
printf '%s' "$DISK" | grep -Eq '^[a-zA-Z0-9]+$' || reply_error "Invalid disk name"
TARGET_DISK="/dev/${DISK}"
[ -b "$TARGET_DISK" ] || reply_error "Device not found: $TARGET_DISK"

ROOT_A_DEV=$(root_slot_device DS_PRIMARY DAYSHIELD_ROOT_A)
ROOT_B_DEV=$(root_slot_device DS_SECONDARY DAYSHIELD_ROOT_B)
BOOT_DEV=$(blkid -L DAYSHIELD_BOOT 2>/dev/null || true)
[ -n "$ROOT_A_DEV" ] && [ -n "$ROOT_B_DEV" ] && [ -n "$BOOT_DEV" ] || reply_error "No DayShield Primary/Secondary installation found on this system"
require_on_target_disk "$ROOT_A_DEV"
require_on_target_disk "$ROOT_B_DEV"
require_on_target_disk "$BOOT_DEV"

EFI_DEV=$(lsblk -nr -o NAME,PARTTYPE "$TARGET_DISK" 2>/dev/null | awk 'tolower($2) ~ /c12a7328-f81f-11d2-ba4b-00a0c93ec93b|ef00/ { print "/dev/" $1; exit }')
if [ -z "$EFI_DEV" ]; then
  case "$DISK" in
    nvme*|mmcblk*) EFI_DEV="/dev/${DISK}p2" ;;
    *) EFI_DEV="/dev/${DISK}2" ;;
  esac
fi
[ -b "$EFI_DEV" ] || reply_error "EFI partition not found on $TARGET_DISK"

ROOTFS=$(find_rootfs || true)
[ -n "$ROOTFS" ] && [ -f "$ROOTFS" ] || reply_error "rootfs archive not found; ensure the ISO contains /installer/rootfs.tar.zst"

ACTIVE_MOUNT=$(mktemp -d)
BOOT_MOUNT=$(mktemp -d)
mount -o ro "$BOOT_DEV" "$BOOT_MOUNT" 2>/dev/null || reply_error "Failed to mount shared boot partition"
ACTIVE_SLOT=$(read_default_slot)
case "$ACTIVE_SLOT" in
  a) ACTIVE_DEV="$ROOT_A_DEV"; INACTIVE_SLOT="b"; INACTIVE_DEV="$ROOT_B_DEV"; INACTIVE_LABEL="DS_SECONDARY" ;;
  b) ACTIVE_DEV="$ROOT_B_DEV"; INACTIVE_SLOT="a"; INACTIVE_DEV="$ROOT_A_DEV"; INACTIVE_LABEL="DS_PRIMARY" ;;
  *) reply_error "Invalid active slot detected: $ACTIVE_SLOT" ;;
esac
umount "$BOOT_MOUNT" 2>/dev/null || true

mount -o ro "$ACTIVE_DEV" "$ACTIVE_MOUNT" 2>/dev/null || reply_error "Failed to mount active rootfs slot $ACTIVE_SLOT"
mkfs.ext4 -F -L "$INACTIVE_LABEL" "$INACTIVE_DEV" >>"$LOG" 2>&1 || reply_error "Failed to format inactive rootfs slot $INACTIVE_SLOT"
mount "$INACTIVE_DEV" "$TARGET" 2>/dev/null || reply_error "Failed to mount inactive rootfs slot $INACTIVE_SLOT"

extract_rootfs "$ROOTFS" "$TARGET" >>"$LOG" 2>&1 || reply_error "Failed to extract ISO rootfs into inactive slot"
copy_persistent_state
mkdir -p "${TARGET}/etc/dayshield"
printf '%s\n' "$INACTIVE_SLOT" > "${TARGET}/etc/dayshield/rootfs-slot"
write_fstab
write_iso_marker

mount "$BOOT_DEV" "$BOOT_MOUNT" 2>/dev/null || reply_error "Failed to mount shared boot partition"
ensure_active_boot_files "$ACTIVE_SLOT"
install_slot_boot_files "$INACTIVE_SLOT" "${TARGET}/boot" || reply_error "Failed to copy ISO kernel/initrd into inactive boot slot"
umount "$BOOT_MOUNT" 2>/dev/null || true

mkdir -p "${TARGET}/boot"
mount "$BOOT_DEV" "${TARGET}/boot" 2>/dev/null || reply_error "Failed to mount shared boot on target"
mkdir -p "${TARGET}/boot/efi"
mount "$EFI_DEV" "${TARGET}/boot/efi" 2>/dev/null || reply_error "Failed to mount EFI partition on target"
for fs in proc sys dev dev/pts run; do
  mkdir -p "${TARGET}/${fs}"
  mount --bind "/${fs}" "${TARGET}/${fs}" >/dev/null 2>&1 || true
done

write_grub_config
schedule_trial_boot
sync

reply_ok "$ACTIVE_SLOT" "$INACTIVE_SLOT"
