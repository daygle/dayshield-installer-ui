#!/bin/sh
# configure-system.sh - Apply hostname, admin password, network, and service settings
# Query string params:
#   disk=<name>       (e.g. sda)
#   hostname=<name>         (e.g. dayshield)
#   password=<pass>         (plain-text; hashed with openssl or chpasswd)
#   iface=<name>            (e.g. eth0)
#   lan_ip=<address>        (e.g. 192.168.1.1)
#   lan_prefix=<prefix>     (e.g. 24)
#   lan_dhcp_enable=<yes|no> (e.g. yes)
#   dhcp_start=<address>    (required when lan_dhcp_enable=yes)
#   dhcp_end=<address>      (required when lan_dhcp_enable=yes)
#   wan_iface=<name>        (e.g. eth1)
#   wan_type=<dhcp|pppoe>   (e.g. dhcp)
#   wan_pppoe_user=<user>   (required for pppoe)
#   wan_pppoe_pass=<pass>   (required for pppoe)
# Output: JSON  { "ok": true } | { "error": "message" }
#
# Assumes /mnt/target is mounted (install-rootfs + install-bootloader done).
# Must be POSIX-compliant and run as root.

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'

# ── Parse CGI query string ──────────────────────────────────
parse_param() {
  # Usage: parse_param QUERY_STRING key
  _raw=$(printf '%s' "$1" | tr '&' '\n' | grep "^${2}=" | head -n1 | sed "s/^${2}=//")
  # Decode URL-encoded bytes portably: awk handles + as space and %XX as the
  # corresponding byte, without relying on the non-POSIX \x printf extension
  # that is silently broken on dash (the default /bin/sh on Debian/Ubuntu).
  printf '%s' "${_raw}" | awk '
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

trim_ws() {
  # Trim leading/trailing whitespace from a scalar value.
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

validate_ipv4() {
  _ip="$1"
  case "$_ip" in
    ''|*[!0-9.]*|.*|*.) return 1 ;;
  esac
  IFS='.' read -r _o1 _o2 _o3 _o4 << EOF
$_ip
EOF
  for _octet in "$_o1" "$_o2" "$_o3" "$_o4"; do
    case "$_octet" in
      0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

prefix_to_netmask() {
  case "$1" in
    0)  printf '0.0.0.0' ;;
    1)  printf '128.0.0.0' ;;
    2)  printf '192.0.0.0' ;;
    3)  printf '224.0.0.0' ;;
    4)  printf '240.0.0.0' ;;
    5)  printf '248.0.0.0' ;;
    6)  printf '252.0.0.0' ;;
    7)  printf '254.0.0.0' ;;
    8)  printf '255.0.0.0' ;;
    9)  printf '255.128.0.0' ;;
    10) printf '255.192.0.0' ;;
    11) printf '255.224.0.0' ;;
    12) printf '255.240.0.0' ;;
    13) printf '255.248.0.0' ;;
    14) printf '255.252.0.0' ;;
    15) printf '255.254.0.0' ;;
    16) printf '255.255.0.0' ;;
    17) printf '255.255.128.0' ;;
    18) printf '255.255.192.0' ;;
    19) printf '255.255.224.0' ;;
    20) printf '255.255.240.0' ;;
    21) printf '255.255.248.0' ;;
    22) printf '255.255.252.0' ;;
    23) printf '255.255.254.0' ;;
    24) printf '255.255.255.0' ;;
    25) printf '255.255.255.128' ;;
    26) printf '255.255.255.192' ;;
    27) printf '255.255.255.224' ;;
    28) printf '255.255.255.240' ;;
    29) printf '255.255.255.248' ;;
    30) printf '255.255.255.252' ;;
    31) printf '255.255.255.254' ;;
    32) printf '255.255.255.255' ;;
    *) return 1 ;;
  esac
}

json_err() {
  _msg=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"error":"%s"}\n' "${_msg}"
  exit 0
}

# ── Collect and validate inputs ──────────────────────────────
# Support both GET query parameters and POST bodies for CGI scripts.
POST_BODY=""
if [ "${REQUEST_METHOD:-GET}" = "POST" ] && [ -n "${CONTENT_LENGTH:-}" ]; then
  POST_BODY=$(dd bs=1 count="${CONTENT_LENGTH}" 2>/dev/null || true)
fi
QS="${QUERY_STRING:-}"
if [ -n "${POST_BODY}" ]; then
  if [ -n "${QS}" ]; then
    QS="${QS}&${POST_BODY}"
  else
    QS="${POST_BODY}"
  fi
fi

DISK=$(parse_param    "${QS}" disk)
HOSTNAME=$(parse_param "${QS}" hostname)
PASSWORD=$(parse_param "${QS}" password)
IFACE=$(parse_param   "${QS}" iface)
LAN_IP=$(parse_param  "${QS}" lan_ip)
LAN_PREFIX=$(parse_param "${QS}" lan_prefix)
LAN_DHCP=$(parse_param "${QS}" lan_dhcp_enable)
WAN_IFACE=$(parse_param "${QS}" wan_iface)
WAN_TYPE=$(parse_param "${QS}" wan_type)
WAN_PPPOE_USER=$(parse_param "${QS}" wan_pppoe_user)
WAN_PPPOE_PASS=$(parse_param "${QS}" wan_pppoe_pass)
DHCP_START=$(parse_param "${QS}" dhcp_start)
DHCP_END=$(parse_param "${QS}" dhcp_end)

# Trim whitespace
DISK=$(trim_ws "${DISK}")
HOSTNAME=$(trim_ws "${HOSTNAME}")
PASSWORD=$(trim_ws "${PASSWORD}")
IFACE=$(trim_ws "${IFACE}")
LAN_IP=$(trim_ws "${LAN_IP}")
LAN_PREFIX=$(trim_ws "${LAN_PREFIX}")
LAN_DHCP=$(trim_ws "${LAN_DHCP}")
WAN_IFACE=$(trim_ws "${WAN_IFACE}")
WAN_TYPE=$(trim_ws "${WAN_TYPE}")
WAN_PPPOE_USER=$(trim_ws "${WAN_PPPOE_USER}")
WAN_PPPOE_PASS=$(trim_ws "${WAN_PPPOE_PASS}")
DHCP_START=$(trim_ws "${DHCP_START}")
DHCP_END=$(trim_ws "${DHCP_END}")

# Required fields
[ -z "${DISK}" ]       && json_err "disk is required"
[ -z "${HOSTNAME}" ]   && json_err "hostname is required"
[ -z "${PASSWORD}" ]   && json_err "password is required"
[ -z "${IFACE}" ]      && json_err "iface is required"
[ -z "${LAN_IP}" ]     && json_err "lan_ip is required"
[ -z "${LAN_PREFIX}" ] && json_err "lan_prefix is required"

# Validate disk: must be a simple device name (no slashes, no dots at start)
case "${DISK}" in
  */*|.*|'') json_err "invalid disk name" ;;
esac

# Validate hostname: RFC 952/1123 labels, up to 63 chars each, total <= 253
# (We keep it simple: only allow [a-z0-9-] labels separated by dots.)
case "${HOSTNAME}" in
  ''|*[!a-zA-Z0-9.-]*) json_err "invalid hostname" ;;
esac

# Validate iface: simple alphanumeric + dash/underscore, no slash
case "${IFACE}" in
  ''|*[!a-zA-Z0-9_-]*) json_err "invalid iface name" ;;
esac

# Validate IP
validate_ipv4 "${LAN_IP}" || json_err "invalid lan_ip"

# Validate prefix (0-32)
case "${LAN_PREFIX}" in
  ''|*[!0-9]*) json_err "invalid lan_prefix" ;;
esac
[ "${LAN_PREFIX}" -ge 0 ] 2>/dev/null && [ "${LAN_PREFIX}" -le 32 ] 2>/dev/null || json_err "lan_prefix out of range"

# Normalise dhcp flag
case "${LAN_DHCP}" in
  yes|Yes|YES|1|true|True|TRUE) LAN_DHCP=yes ;;
  *) LAN_DHCP=no ;;
esac

# Normalize WAN type
case "${WAN_TYPE}" in
  ''|dhcp|DHCP|Dhcp) WAN_TYPE=dhcp ;;
  pppoe|PPPoE|Pppoe) WAN_TYPE=pppoe ;;
  *) json_err "invalid wan_type" ;;
esac

if [ -z "${WAN_IFACE}" ]; then
  json_err "wan_iface is required"
fi
case "${WAN_IFACE}" in
  ''|*[!a-zA-Z0-9_-]*) json_err "invalid wan_iface" ;;
esac

if [ "${WAN_TYPE}" = "pppoe" ]; then
  [ -n "${WAN_PPPOE_USER}" ] || json_err "wan_pppoe_user is required for pppoe"
  [ -n "${WAN_PPPOE_PASS}" ] || json_err "wan_pppoe_pass is required for pppoe"
fi

if [ "${LAN_DHCP}" = 'yes' ]; then
  [ -n "${DHCP_START}" ] || json_err "dhcp_start is required when lan_dhcp_enable is yes"
  [ -n "${DHCP_END}" ] || json_err "dhcp_end is required when lan_dhcp_enable is yes"
  validate_ipv4 "${DHCP_START}" || json_err "invalid dhcp_start"
  validate_ipv4 "${DHCP_END}" || json_err "invalid dhcp_end"
elif [ -n "${DHCP_START}" ] || [ -n "${DHCP_END}" ]; then
  json_err "dhcp_start and dhcp_end must both be provided or both empty"
fi

TARGET="/mnt/target"
[ -d "${TARGET}" ] || json_err "${TARGET} is not mounted"

# ── 1. Hostname ──────────────────────────────────────────────
printf '%s\n' "${HOSTNAME}" > "${TARGET}/etc/hostname"
chmod 644 "${TARGET}/etc/hostname"

# /etc/hosts – replace or add 127.0.1.1 line
HOSTS="${TARGET}/etc/hosts"
if grep -q '^127\.0\.1\.1' "${HOSTS}" 2>/dev/null; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${HOSTNAME}/" "${HOSTS}"
else
  printf '127.0.1.1\t%s\n' "${HOSTNAME}" >> "${HOSTS}"
fi

# ── 2. Admin password ────────────────────────────────────────
# Try openssl first (available in the live environment); fall back to chpasswd.
if command -v openssl >/dev/null 2>&1; then
  HASHED=$(openssl passwd -6 "${PASSWORD}")
  # Use chroot + chpasswd if available for proper shadow update
  if [ -x "${TARGET}/usr/sbin/chpasswd" ]; then
    printf 'root:%s\n' "${HASHED}" | chroot "${TARGET}" chpasswd -e
  elif [ -x "${TARGET}/usr/bin/chpasswd" ]; then
    printf 'root:%s\n' "${HASHED}" | chroot "${TARGET}" chpasswd -e
  else
    # Direct shadow edit as last resort
    SHADOW="${TARGET}/etc/shadow"
    if [ -f "${SHADOW}" ]; then
      sed -i "s|^root:[^:]*:|root:${HASHED}:|" "${SHADOW}"
    fi
  fi
else
  # openssl not available – use chpasswd in the chroot directly
  if [ -x "${TARGET}/usr/sbin/chpasswd" ]; then
    printf 'root:%s\n' "${PASSWORD}" | chroot "${TARGET}" chpasswd
  elif [ -x "${TARGET}/usr/bin/chpasswd" ]; then
    printf 'root:%s\n' "${PASSWORD}" | chroot "${TARGET}" chpasswd
  else
    json_err "cannot set password: neither openssl nor chpasswd is available"
  fi
fi

# ── 3. Network interface configuration ───────────────────────
NETWORK_DIR="${TARGET}/etc/network"
mkdir -p "${NETWORK_DIR}/interfaces.d"

# Write /etc/network/interfaces
INTERFACES_FILE="${NETWORK_DIR}/interfaces"
printf '# Generated by dayshield installer\n' > "${INTERFACES_FILE}"
printf 'source /etc/network/interfaces.d/*\n\n' >> "${INTERFACES_FILE}"
printf 'auto lo\n' >> "${INTERFACES_FILE}"
printf 'iface lo inet loopback\n\n' >> "${INTERFACES_FILE}"

# LAN interface — always static; lan_dhcp_enable controls the DHCP server, not this interface
LAN_NETMASK=$(prefix_to_netmask "${LAN_PREFIX}") || json_err "invalid lan_prefix"
printf 'auto %s\n' "${IFACE}" >> "${INTERFACES_FILE}"
printf 'iface %s inet static\n' "${IFACE}" >> "${INTERFACES_FILE}"
printf '    address %s\n' "${LAN_IP}" >> "${INTERFACES_FILE}"
printf '    netmask %s\n' "${LAN_NETMASK}" >> "${INTERFACES_FILE}"
chmod 644 "${INTERFACES_FILE}"

# ── 3a. DayShield installed runtime finalization ─────────────
SHARED_FINALIZER="${TARGET}/usr/local/lib/dayshield/installer-finalize.sh"
if [ -x "${SHARED_FINALIZER}" ]; then
  if ! chroot "${TARGET}" /usr/local/lib/dayshield/installer-finalize.sh \
      / "${HOSTNAME}" "${PASSWORD}" "${WAN_IFACE}" "${WAN_TYPE}" \
      "${WAN_PPPOE_USER}" "${WAN_PPPOE_PASS}" "${IFACE}" "${LAN_IP}" \
      "${LAN_PREFIX}" "${DHCP_START}" "${DHCP_END}" >/dev/null 2>&1; then
    json_err "installer runtime finalization failed"
  fi
else
  json_err "target post-install finalizer is missing"
fi

# ── 4. WireGuard placeholder ─────────────────────────────────
# Create the WireGuard config directory and a placeholder wg0.conf.
# Use a umask 077 subshell so that both the directory and the file are
# created with restrictive permissions from the outset — this eliminates
# the permission window that would otherwise exist between creation and
# a subsequent chmod call.
#
# Note: wg-quick / the kernel interface *requires* that the config file
# be owned by root and not world-readable.  The wireguard-tools package
# ships a systemd-path unit that refuses to load configs with permissions
# looser than 0600, so we must not rely on a separate chmod.
#
# IMPORTANT: this config is intentionally skeletal.  dayshield-core will
# write the real PrivateKey, Address, DNS, and Peer sections on first
# boot via its own key-generation routine.  The installer should NOT
# generate or store WireGuard keys — doing so would mean the private key
# transits the installer API in plain text.
#
# Consumers of this stub must not attempt to bring up wg0 until
# dayshield-core has populated the missing fields; the [Interface] block
# below is deliberately incomplete and wg-quick will refuse to start it.
#
# The comment "do not edit manually" is intentional: dayshield-core owns
# this file after first boot.  Manual edits will be overwritten.
#
# wireguard-tools note: wg-quick does not support any "include:" directive --
# only standard [Interface] and [Peer] sections are valid.
(
  umask 077
  mkdir -p "${TARGET}/etc/wireguard"
  printf '# WireGuard managed by dayshield-core - do not edit manually\n[Interface]\n# PrivateKey and Address will be written by dayshield-core on first boot\n# PrivateKey =\n# Address =\n# DNS =\n\n# Peer sections will be added by dayshield-core\n' > "${TARGET}/etc/wireguard/wg0.conf"
)

# ── 5. Enable required services ──────────────────────────────
# We use chroot + systemctl enable (or manual symlink as fallback).
WANTED_SERVICES="ssh networking wg-quick@wg0"

for _svc in ${WANTED_SERVICES}; do
  if chroot "${TARGET}" systemctl enable "${_svc}" 2>/dev/null; then
    : # enabled via systemctl
  else
    # Fallback: create the wanted symlink manually if the unit file exists.
    # This covers environments where D-Bus / PID-1 is not available in the chroot.
    _unit_file=""
    for _dir in lib/systemd/system usr/lib/systemd/system etc/systemd/system; do
      if [ -f "${TARGET}/${_dir}/${_svc}.service" ]; then
        _unit_file="${TARGET}/${_dir}/${_svc}.service"
        _unit_rel="/${_dir}/${_svc}.service"
        break
      fi
    done
    if [ -n "${_unit_file}" ]; then
      # Determine WantedBy from the unit file (default to multi-user.target)
      _wanted_by=$(grep '^WantedBy=' "${_unit_file}" | head -n1 | sed 's/^WantedBy=//' | tr -d ' ')
      _wanted_by="${_wanted_by:-multi-user.target}"
      _wants_dir="${TARGET}/etc/systemd/system/${_wanted_by}.wants"
      mkdir -p "${_wants_dir}"
      ln -sf "${_unit_rel}" "${_wants_dir}/${_svc}.service" 2>/dev/null || true
    fi
  fi
done

# ── 6. Firewall (nftables) skeleton ──────────────────────────
# Write a minimal nftables ruleset that:
#   - Allows established/related traffic
#   - Allows SSH (port 22) and the installer API (port 8080) inbound
#   - Allows ICMP
#   - Drops everything else inbound
#   - Allows all outbound
#
# dayshield-core will overwrite this with its own policy on first boot;
# this skeleton exists only to ensure the firewall is not left open
# during the first boot before dayshield-core runs.
NFT_CONF="${TARGET}/etc/nftables.conf"
printf '#!/usr/sbin/nft -f\n# Skeleton ruleset - managed by dayshield-core after first boot\ntable inet filter {\n    chain input {\n        type filter hook input priority 0; policy drop;\n        ct state established,related accept\n        iif lo accept\n        ip protocol icmp accept\n        ip6 nexthdr ipv6-icmp accept\n        tcp dport { 22, 8080 } accept\n    }\n    chain forward {\n        type filter hook forward priority 0; policy drop;\n    }\n    chain output {\n        type filter hook output priority 0; policy accept;\n    }\n}\n' > "${NFT_CONF}"
chmod 644 "${NFT_CONF}"

# Enable nftables service
if chroot "${TARGET}" systemctl enable nftables 2>/dev/null; then
  :
else
  for _dir in lib/systemd/system usr/lib/systemd/system etc/systemd/system; do
    if [ -f "${TARGET}/${_dir}/nftables.service" ]; then
      _wanted_by=$(grep '^WantedBy=' "${TARGET}/${_dir}/nftables.service" | head -n1 | sed 's/^WantedBy=//' | tr -d ' ')
      _wanted_by="${_wanted_by:-multi-user.target}"
      _wants_dir="${TARGET}/etc/systemd/system/${_wanted_by}.wants"
      mkdir -p "${_wants_dir}"
      ln -sf "/${_dir}/nftables.service" "${_wants_dir}/nftables.service" 2>/dev/null || true
      break
    fi
  done
fi

# ── 7. Disable unnecessary services (attack-surface reduction) ────────────
# These services are commonly enabled by default on Debian-family installs
# but are not needed on a dedicated security appliance.  Disabling them
# here means they will not start on first boot even before dayshield-core
# has a chance to enforce its own policy.
#
# avahi-daemon : mDNS/DNS-SD responder – leaks hostnames on LAN
# cups         : printing daemon – not needed on an appliance
# bluetooth    : BT stack – not present on most server hardware, harmless to mask
DISABLE_SERVICES="avahi-daemon cups bluetooth"

for _svc in ${DISABLE_SERVICES}; do
  # mask is stronger than disable: prevents manual start as well
  chroot "${TARGET}" systemctl mask "${_svc}" 2>/dev/null || true
done

# ── 8. SSH hardening ─────────────────────────────────────────
# Harden the installed SSH daemon configuration.
# We write a drop-in under /etc/ssh/sshd_config.d/ so we don't clobber
# the distro-provided sshd_config (which may be updated by future package
# upgrades).  OpenSSH >= 8.2 (Debian 11+) reads this directory by default.
#
# Settings applied:
#   PermitRootLogin prohibit-password  – root login only via key, not password
#   PasswordAuthentication no          – key-only auth for all accounts
#   PermitEmptyPasswords no            – belt-and-suspenders
#   ChallengeResponseAuthentication no – disable PAM keyboard-interactive
#   X11Forwarding no                   – no X11 forwarding on an appliance
#   AllowTcpForwarding no              – prevent use as a SOCKS proxy
#   MaxAuthTries 4                     – reduce brute-force window
#   LoginGraceTime 30                  – reduce auth window to 30 s
#
# Note: PasswordAuthentication no means the installer password set above is
# only usable for local console login and sudo, not SSH.  The operator must
# install an SSH public key (via dayshield-core or manually) before remote
# SSH access will work.  This is intentional.
SSHD_DROP_IN_DIR="${TARGET}/etc/ssh/sshd_config.d"
mkdir -p "${SSHD_DROP_IN_DIR}"
SSHD_DROP_IN="${SSHD_DROP_IN_DIR}/99-dayshield-hardening.conf"
printf '# dayshield installer hardening - do not edit manually\n# dayshield-core will manage this file after first boot\nPermitRootLogin prohibit-password\nPasswordAuthentication no\nPermitEmptyPasswords no\nChallengeResponseAuthentication no\nX11Forwarding no\nAllowTcpForwarding no\nMaxAuthTries 4\nLoginGraceTime 30\n' > "${SSHD_DROP_IN}"
chmod 644 "${SSHD_DROP_IN}"

# ── 9. Kernel hardening (sysctl) ─────────────────────────────
# Write sysctl tunables to a drop-in file.  These are applied on first boot
# by the sysctl service (which reads /etc/sysctl.d/*.conf).
#
# Tunables:
#   net.ipv4.conf.all.rp_filter=1           – strict reverse-path filtering
#   net.ipv4.conf.default.rp_filter=1
#   net.ipv4.conf.all.accept_source_route=0 – drop source-routed packets
#   net.ipv4.conf.default.accept_source_route=0
#   net.ipv4.conf.all.accept_redirects=0    – ignore ICMP redirects
#   net.ipv4.conf.default.accept_redirects=0
#   net.ipv6.conf.all.accept_redirects=0
#   net.ipv6.conf.default.accept_redirects=0
#   net.ipv4.conf.all.send_redirects=0      – don't send ICMP redirects
#   net.ipv4.conf.default.send_redirects=0
#   net.ipv4.tcp_syncookies=1               – SYN flood protection
#   net.ipv4.icmp_echo_ignore_broadcasts=1  – ignore broadcast pings (smurf)
#   net.ipv4.conf.all.log_martians=1        – log packets with impossible addrs
#   kernel.randomize_va_space=2             – full ASLR
#   kernel.dmesg_restrict=1                 – restrict dmesg to root
#   fs.protected_hardlinks=1               – prevent hardlink attacks
#   fs.protected_symlinks=1                – prevent symlink attacks
SYSCTL_DROP_IN="${TARGET}/etc/sysctl.d/99-dayshield-hardening.conf"
mkdir -p "${TARGET}/etc/sysctl.d"
printf '# dayshield installer - kernel hardening\nnet.ipv4.conf.all.rp_filter = 1\nnet.ipv4.conf.default.rp_filter = 1\nnet.ipv4.conf.all.accept_source_route = 0\nnet.ipv4.conf.default.accept_source_route = 0\nnet.ipv4.conf.all.accept_redirects = 0\nnet.ipv4.conf.default.accept_redirects = 0\nnet.ipv6.conf.all.accept_redirects = 0\nnet.ipv6.conf.default.accept_redirects = 0\nnet.ipv4.conf.all.send_redirects = 0\nnet.ipv4.conf.default.send_redirects = 0\nnet.ipv4.tcp_syncookies = 1\nnet.ipv4.icmp_echo_ignore_broadcasts = 1\nnet.ipv4.conf.all.log_martians = 1\nkernel.randomize_va_space = 2\nkernel.dmesg_restrict = 1\nfs.protected_hardlinks = 1\nfs.protected_symlinks = 1\n' > "${SYSCTL_DROP_IN}"
chmod 644 "${SYSCTL_DROP_IN}"

# ── 10. Unattended-upgrades (security updates) ───────────────
# Install a minimal unattended-upgrades configuration so that security
# updates are applied automatically.  This is a belt-and-suspenders
# measure: dayshield-core manages its own update policy, but having
# unattended-upgrades as a backstop means the appliance is not left
# vulnerable if dayshield-core is temporarily offline.
#
# We only configure the security suite — not stable-updates — to minimise
# the risk of an unattended upgrade breaking a production appliance.
UA_DIR="${TARGET}/etc/apt/apt.conf.d"
mkdir -p "${UA_DIR}"
printf '// dayshield installer - unattended security updates\nUnattended-Upgrade::Origins-Pattern {\n    "origin=Debian,codename=${distro_codename},label=Debian-Security";\n};\nUnattended-Upgrade::Package-Blacklist {};\nUnattended-Upgrade::AutoFixInterruptedDpkg "true";\nUnattended-Upgrade::MinimalSteps "true";\nUnattended-Upgrade::InstallOnShutdown "false";\nUnattended-Upgrade::Remove-Unused-Kernel-Packages "true";\nUnattended-Upgrade::Remove-New-Unused-Dependencies "true";\nUnattended-Upgrade::Automatic-Reboot "false";\n' > "${UA_DIR}/51-dayshield-unattended-upgrades"
chmod 644 "${UA_DIR}/51-dayshield-unattended-upgrades"

# Enable the periodic apt updates that drive unattended-upgrades.
# The 20auto-upgrades file is the standard trigger recognised by the
# unattended-upgrades package on Debian/Ubuntu.
printf '// dayshield installer - enable periodic updates\nAPT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > "${UA_DIR}/20auto-upgrades"
chmod 644 "${UA_DIR}/20auto-upgrades"

# ── Done ─────────────────────────────────────────────────────
DAYSHIELD_SVC_WARNING=""

# Collect warnings for services that could not be enabled/disabled.
# (Currently informational only; we do not fail the install for this.)
for _svc in ${WANTED_SERVICES}; do
  if ! chroot "${TARGET}" systemctl is-enabled "${_svc}" >/dev/null 2>&1; then
    DAYSHIELD_SVC_WARNING="${DAYSHIELD_SVC_WARNING:+${DAYSHIELD_SVC_WARNING}, }${_svc}"
  fi
done

if [ -n "${DAYSHIELD_SVC_WARNING}" ]; then
  WARN_JSON=$(printf '%s' "${DAYSHIELD_SVC_WARNING}" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"ok":true,"warning":"%s"}\n' "${WARN_JSON}"
else
  printf '{"ok":true}\n'
fi

