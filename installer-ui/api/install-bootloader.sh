#!/bin/sh
# install-bootloader.sh - Install GRUB for the DayShield image-based update layout.
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

# Force blkid to re-probe devices (bypasses stale cache; needed in live environments)
blkid -c /dev/null >/dev/null 2>&1 || true

find_dev_by_label() {
  _label="$1"
  _dev=$(blkid -L "$_label" 2>/dev/null || true)
  [ -n "$_dev" ] || _dev=$(blkid -t LABEL="$_label" -o device 2>/dev/null | head -n1 || true)
  [ -n "$_dev" ] || _dev=$(blkid 2>/dev/null | grep "LABEL=\"$_label\"" | sed 's/:.*//' | head -n1 || true)
  printf '%s' "$_dev"
}

BOOT_DEV=$(find_dev_by_label "DAYSHIELD_BOOT")
ROOT_A_DEV=$(find_dev_by_label "DS_ROOT_A")
ROOT_B_DEV=$(find_dev_by_label "DS_ROOT_B")
[ -n "$BOOT_DEV" ] && [ -n "$ROOT_A_DEV" ] && [ -n "$ROOT_B_DEV" ] \
  || json_error "Required boot/root labels were not found (DAYSHIELD_BOOT, DS_ROOT_A, DS_ROOT_B)"

# ── Write the A/B grub.cfg ──────────────────────────────────────────────────
# Hand-write the GRUB config — we don't want grub-mkconfig pulling in os-prober
# entries or stomping our slot scheme.  Slot selection is driven by grubenv
# variables that dayshield-core writes when applying an update:
#   saved_entry          — "ds_a" or "ds_b" (whichever slot to boot next)
#   fallback_entry       — slot to revert to if boot_attempts_left hits 0
#   boot_state           — "trying" while a new slot is on probation, "confirmed" after signal-boot-success
#   boot_attempts_left   — initialised to 3 on apply; GRUB decrements each boot until userspace confirms
#
# The first boot of a freshly-applied slot has tries_left=3 → 2 → 1 → 0; on the
# fourth attempt without confirmation, GRUB switches default to fallback_entry.

mkdir -p "${TARGET}/boot/grub"
cat > "${TARGET}/boot/grub/grub.cfg" <<'GRUB_EOF'
set timeout=0
set timeout_style=hidden

# Load persisted slot state.
load_env

# Defaults for first-ever boot.
if [ -z "${saved_entry}" ];   then set saved_entry=ds_a;     fi
if [ -z "${boot_state}" ];    then set boot_state=confirmed; fi

# Slot-fallback routing: if a probationary boot has exhausted its retries,
# switch the default to the fallback entry on this boot.
if [ "${boot_state}" = "trying" ]; then
    if [ "${boot_attempts_left}" = "0" ] && [ -n "${fallback_entry}" ]; then
        set default="${fallback_entry}"
    else
        set default="${saved_entry}"
    fi
else
    set default="${saved_entry}"
fi

# Count the boot attempt (GRUB has no arithmetic; we cascade explicit values).
if [ "${boot_state}" = "trying" ]; then
    if [ "${boot_attempts_left}" = "3" ]; then
        set boot_attempts_left=2
        save_env boot_attempts_left
    elif [ "${boot_attempts_left}" = "2" ]; then
        set boot_attempts_left=1
        save_env boot_attempts_left
    elif [ "${boot_attempts_left}" = "1" ]; then
        set boot_attempts_left=0
        save_env boot_attempts_left
    fi
fi

menuentry 'DayShield (slot A)' --id ds_a {
    search --no-floppy --label DAYSHIELD_BOOT --set=root
    linux /dayshield/slot-a/vmlinuz root=LABEL=DS_ROOT_A ro
    initrd /dayshield/slot-a/initrd.img
}

menuentry 'DayShield (slot B)' --id ds_b {
    search --no-floppy --label DAYSHIELD_BOOT --set=root
    linux /dayshield/slot-b/vmlinuz root=LABEL=DS_ROOT_B ro
    initrd /dayshield/slot-b/initrd.img
}
GRUB_EOF

# ── Seed grubenv with a clean install state ─────────────────────────────────
# Slot A is active; no probation in effect.
if command -v grub-editenv >/dev/null 2>&1; then
  grub-editenv "${TARGET}/boot/grub/grubenv" create 2>/dev/null || true
  grub-editenv "${TARGET}/boot/grub/grubenv" set saved_entry=ds_a
  grub-editenv "${TARGET}/boot/grub/grubenv" set boot_state=confirmed
  grub-editenv "${TARGET}/boot/grub/grubenv" unset boot_attempts_left  || true
  grub-editenv "${TARGET}/boot/grub/grubenv" unset fallback_entry      || true
fi

# Disable grub-mkconfig — we manage grub.cfg by hand to keep the A/B logic
# pristine.  /etc/default/grub still gets a minimal file so package upgrades
# don't error out, but it has no effect on our hand-written grub.cfg.
cat > "${TARGET}/etc/default/grub" <<'EOF'
# This file is intentionally minimal.  DayShield manages /boot/grub/grub.cfg
# directly (slot-aware A/B layout); grub-mkconfig is not used.
GRUB_DEFAULT=saved
GRUB_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_DISTRIBUTOR="DayShield"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL_INPUT=console
GRUB_DISABLE_OS_PROBER=true
EOF

# Mask 09_dayshield (legacy single-rootfs entry) if it exists.
rm -f "${TARGET}/etc/grub.d/09_dayshield" 2>/dev/null || true

json_ok "$warning"
