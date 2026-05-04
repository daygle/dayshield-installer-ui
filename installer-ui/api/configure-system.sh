#!/bin/sh
# configure-system.sh - Apply hostname, admin password, network, and service settings
# Query string params:
#   disk=<name>       (e.g. sda)
#   hostname=<name>   (e.g. dayshield)
#   password=<pass>   (plain-text; hashed with openssl or chpasswd)
#   iface=<name>      (e.g. eth0)
# Output: JSON  { "ok": true } | { "error": "message" }
#
# Assumes /mnt/target is mounted (install-rootfs + install-bootloader done).
# Must be POSIX-compliant and run as root.

set -eu

printf 'Content-Type: application/json\r\n'
printf '\r\n'

# ── Parse CGI query string ────────────────────────────────────────
parse_param() {
  # Usage: parse_param QUERY_STRING key
  printf '%s' "$1" | tr '&' '\n' | grep "^${2}=" | head -n1 | sed "s/^${2}=//" | \
    sed 's/+/ /g' | sed 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g' | xargs printf '%b'
}

trim_ws() {
  # Trim leading/trailing whitespace from a scalar value.
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

QS="${QUERY_STRING:-}"
DISK=$(parse_param "$QS" "disk")
HOSTNAME=$(parse_param "$QS" "hostname")
PASSWORD=$(parse_param "$QS" "password")
IFACE=$(parse_param "$QS" "iface")
WAN_IFACE=$(parse_param "$QS" "wan_iface")
WAN_TYPE=$(parse_param "$QS" "wan_type")
WAN_PPPOE_USER=$(parse_param "$QS" "wan_pppoe_user")
WAN_PPPOE_PASS=$(parse_param "$QS" "wan_pppoe_pass")
LAN_IP=$(parse_param "$QS" "lan_ip")
LAN_PREFIX=$(parse_param "$QS" "lan_prefix")
DHCP_START=$(parse_param "$QS" "dhcp_start")
DHCP_END=$(parse_param "$QS" "dhcp_end")

DISK=$(trim_ws "$DISK")
HOSTNAME=$(trim_ws "$HOSTNAME")
IFACE=$(trim_ws "$IFACE")
WAN_IFACE=$(trim_ws "$WAN_IFACE")
WAN_TYPE=$(trim_ws "$WAN_TYPE")
LAN_IP=$(trim_ws "$LAN_IP")
LAN_PREFIX=$(trim_ws "$LAN_PREFIX")
DHCP_START=$(trim_ws "$DHCP_START")
DHCP_END=$(trim_ws "$DHCP_END")

[ -n "$LAN_IP" ] || LAN_IP="192.168.1.1"
[ -n "$LAN_PREFIX" ] || LAN_PREFIX="24"
[ -n "$DHCP_START" ] || DHCP_START="192.168.1.100"
[ -n "$DHCP_END" ] || DHCP_END="192.168.1.199"

# ── Validate ──────────────────────────────────────────────────────
if [ -z "$DISK" ]; then
  printf '{"error":"Missing required parameter: disk"}\n'; exit 1
fi
if [ -z "$HOSTNAME" ]; then
  printf '{"error":"Missing required parameter: hostname"}\n'; exit 1
fi
if [ -z "$PASSWORD" ]; then
  printf '{"error":"Missing required parameter: password"}\n'; exit 1
fi
if [ -z "$IFACE" ]; then
  printf '{"error":"Missing required parameter: iface"}\n'; exit 1
fi
if [ -z "$WAN_IFACE" ]; then
  printf '{"error":"Missing required parameter: wan_iface"}\n'; exit 1
fi
[ -n "$IFACE" ] && [ -n "$WAN_IFACE" ] || { printf '{"error":"Invalid interface selection"}\n'; exit 1; }
if ! printf '%s' "$IFACE" | grep -Eq '^[A-Za-z0-9_.:-]+$'; then
  printf '{"error":"Invalid LAN interface name"}\n'; exit 1
fi
if ! printf '%s' "$WAN_IFACE" | grep -Eq '^[A-Za-z0-9_.:-]+$'; then
  printf '{"error":"Invalid WAN interface name"}\n'; exit 1
fi
if [ ! -e "/sys/class/net/${IFACE}" ]; then
  printf '{"error":"LAN interface not found on system"}\n'; exit 1
fi
if [ ! -e "/sys/class/net/${WAN_IFACE}" ]; then
  printf '{"error":"WAN interface not found on system"}\n'; exit 1
fi
[ -n "$WAN_TYPE" ] || WAN_TYPE="dhcp"
if [ "$WAN_TYPE" != "dhcp" ] && [ "$WAN_TYPE" != "pppoe" ]; then
  printf '{"error":"Invalid wan_type: expected dhcp or pppoe"}\n'; exit 1
fi
if [ "$WAN_IFACE" = "$IFACE" ]; then
  printf '{"error":"WAN and LAN interfaces must be different"}\n'; exit 1
fi
if [ "$WAN_TYPE" = "pppoe" ] && { [ -z "$WAN_PPPOE_USER" ] || [ -z "$WAN_PPPOE_PASS" ]; }; then
  printf '{"error":"PPPoE selected but username/password missing"}\n'; exit 1
fi

# Installer currently supports a single default /24 LAN plan.
if [ "$LAN_PREFIX" != "24" ]; then
  printf '{"error":"Invalid lan_prefix: only 24 is currently supported"}\n'; exit 1
fi

if ! printf '%s' "$LAN_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  printf '{"error":"Invalid lan_ip"}\n'; exit 1
fi
if ! printf '%s' "$DHCP_START" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  printf '{"error":"Invalid dhcp_start"}\n'; exit 1
fi
if ! printf '%s' "$DHCP_END" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  printf '{"error":"Invalid dhcp_end"}\n'; exit 1
fi

LAN_NET="${LAN_IP%.*}.0"
SUBNET_CIDR="${LAN_NET}/24"

# Validate hostname (RFC 952 / RFC 1123)
if ! printf '%s' "$HOSTNAME" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$'; then
  printf '{"error":"Invalid hostname: must be alphanumeric and hyphens only, max 63 chars"}\n'; exit 1
fi

TARGET="/mnt/target"

if [ ! -d "${TARGET}/etc" ]; then
  printf '{"error":"Target root not found at %s"}\n' "$TARGET"; exit 1
fi

# ── Set hostname ──────────────────────────────────────────────────
printf '%s\n' "$HOSTNAME" > "${TARGET}/etc/hostname"

# /etc/hosts
cat > "${TARGET}/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
EOF

# ── Set admin (root) password ─────────────────────────────────────
# Prefer openssl for deterministic hashed password generation
if command -v openssl >/dev/null 2>&1; then
  HASH=$(openssl passwd -6 -- "$PASSWORD" 2>/dev/null)
elif command -v python3 >/dev/null 2>&1; then
  HASH=$(python3 -c "import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))" "$PASSWORD" 2>/dev/null)
else
  printf '{"error":"Cannot hash password: neither openssl nor python3 found"}\n'; exit 1
fi

if [ -z "$HASH" ]; then
  printf '{"error":"Password hashing failed"}\n'; exit 1
fi

# Update /etc/shadow - replace root entry
if [ -f "${TARGET}/etc/shadow" ]; then
  SHADOW_ESCAPED=$(printf '%s' "$HASH" | sed 's|[&/\\]|\\&|g')
  sed -i "s|^root:[^:]*:|root:${SHADOW_ESCAPED}:|" "${TARGET}/etc/shadow"
else
  printf '{"error":"/etc/shadow not found in target"}\n'; exit 1
fi

# ── Configure LAN interface ───────────────────────────────────────
NETDIR="${TARGET}/etc/dayshield"
mkdir -p "$NETDIR"

# Write DayShield network config
cat > "${NETDIR}/network.conf" << EOF
# DayShield network configuration
# Generated by installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
LAN_IFACE=${IFACE}
WAN_IFACE=${WAN_IFACE}
WAN_TYPE=${WAN_TYPE}
LAN_IP=${LAN_IP}
LAN_PREFIX=${LAN_PREFIX}
LAN_DHCP_ENABLE=yes
LAN_DHCP_START=${DHCP_START}
LAN_DHCP_END=${DHCP_END}
EOF

# Write nftables interface mapping used by /etc/nftables.conf.
mkdir -p "${TARGET}/etc/dayshield/config"
cat > "${TARGET}/etc/dayshield/config/nft-ifaces.conf" << EOF
define WAN_IF = ${WAN_IFACE}
define LAN_IF = ${IFACE}
EOF

# Also write a systemd-networkd .network file if applicable
NETWORKD_DIR="${TARGET}/etc/systemd/network"
mkdir -p "$NETWORKD_DIR"
# Remove generic installer placeholder to avoid match/order conflicts.
rm -f "${NETWORKD_DIR}/10-dayshield-eth.network"
if [ "$WAN_TYPE" = "pppoe" ]; then
cat > "${NETWORKD_DIR}/10-wan.network" << EOF
[Match]
Name=${WAN_IFACE}

[Network]
DHCP=no
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF
mkdir -p "${TARGET}/etc/ppp/peers" "${TARGET}/etc/ppp"
cat > "${TARGET}/etc/ppp/peers/wan" << EOF
plugin rp-pppoe.so ${WAN_IFACE}
user "${WAN_PPPOE_USER}"
noauth
defaultroute
replacedefaultroute
hide-password
persist
maxfail 0
holdoff 5
noipv6
EOF
chmod 600 "${TARGET}/etc/ppp/peers/wan"
SECRETS_LINE="\"${WAN_PPPOE_USER}\" * \"${WAN_PPPOE_PASS}\" *"
printf '%s\n' "${SECRETS_LINE}" > "${TARGET}/etc/ppp/chap-secrets"
printf '%s\n' "${SECRETS_LINE}" > "${TARGET}/etc/ppp/pap-secrets"
chmod 600 "${TARGET}/etc/ppp/chap-secrets" "${TARGET}/etc/ppp/pap-secrets"
else
cat > "${NETWORKD_DIR}/10-wan.network" << EOF
[Match]
Name=${WAN_IFACE}

[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF
fi
cat > "${NETWORKD_DIR}/20-lan.network" << EOF
[Match]
Name=${IFACE}

[Network]
Address=${LAN_IP}/${LAN_PREFIX}
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF

# Seed Unbound resolver config for LAN clients.
mkdir -p "${TARGET}/etc/unbound" "${TARGET}/var/lib/unbound"
# Pre-seed DNSSEC trust anchor (avoids first-boot Unbound failure)
chroot "$TARGET" /usr/sbin/unbound-anchor -a /var/lib/unbound/root.key >/dev/null 2>&1 || true
chroot "$TARGET" chown -R unbound:unbound /var/lib/unbound 2>/dev/null || true
cat > "${TARGET}/etc/unbound/unbound.conf" << EOF
# /etc/unbound/unbound.conf - generated by DayShield installer
server:
  # Bind all IPv4 interfaces to avoid start-up races if LAN address is applied
  # shortly after unbound service activation.
  interface: 0.0.0.0
  port: 53

  do-ip4: yes
  do-ip6: no
  do-udp: yes
  do-tcp: yes

  access-control: 127.0.0.0/8 allow
  access-control: ${SUBNET_CIDR} allow
  access-control: 0.0.0.0/0 refuse

  auto-trust-anchor-file: "/var/lib/unbound/root.key"
  root-hints: "/usr/share/dns/root.hints"

  harden-glue: yes
  harden-dnssec-stripped: yes
  harden-referral-path: yes
  harden-algo-downgrade: yes
  use-caps-for-id: yes
  hide-identity: yes
  hide-version: yes
  qname-minimisation: yes

  cache-min-ttl: 300
  cache-max-ttl: 86400
  neg-cache-size: 4m

  verbosity: 1
  log-queries: no

  num-threads: 2
  msg-cache-slabs: 4
  rrset-cache-slabs: 4
  infra-cache-slabs: 4
  key-cache-slabs: 4
  rrset-cache-size: 256m
  msg-cache-size: 128m

  prefetch: yes

  private-address: 10.0.0.0/8
  private-address: 172.16.0.0/12
  private-address: 192.168.0.0/16
  private-address: 100.64.0.0/10
  private-address: 169.254.0.0/16

  local-zone: "10.in-addr.arpa." nodefault
  local-zone: "16.172.in-addr.arpa." nodefault
  local-zone: "17.172.in-addr.arpa." nodefault
  local-zone: "18.172.in-addr.arpa." nodefault
  local-zone: "19.172.in-addr.arpa." nodefault
  local-zone: "20.172.in-addr.arpa." nodefault
  local-zone: "21.172.in-addr.arpa." nodefault
  local-zone: "22.172.in-addr.arpa." nodefault
  local-zone: "23.172.in-addr.arpa." nodefault
  local-zone: "24.172.in-addr.arpa." nodefault
  local-zone: "25.172.in-addr.arpa." nodefault
  local-zone: "26.172.in-addr.arpa." nodefault
  local-zone: "27.172.in-addr.arpa." nodefault
  local-zone: "28.172.in-addr.arpa." nodefault
  local-zone: "29.172.in-addr.arpa." nodefault
  local-zone: "30.172.in-addr.arpa." nodefault
  local-zone: "31.172.in-addr.arpa." nodefault
  local-zone: "168.192.in-addr.arpa." nodefault

  minimal-responses: yes
EOF

# Keep router mode stable and avoid noisy martian printk spam on deployed
# appliances (especially direct-connect installer fallback remnants).
mkdir -p "${TARGET}/etc/sysctl.d"
cat > "${TARGET}/etc/sysctl.d/99-dayshield-runtime-network.conf" << EOF
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0
net.ipv4.conf.${IFACE}.rp_filter = 2
net.ipv4.conf.${WAN_IFACE}.rp_filter = 2
net.ipv4.conf.${IFACE}.log_martians = 0
net.ipv4.conf.${WAN_IFACE}.log_martians = 0
EOF

# Seed Kea DHCPv4 config for first boot.
mkdir -p "${TARGET}/etc/kea" "${TARGET}/var/lib/kea" "${TARGET}/var/log/kea"
cat > "${TARGET}/etc/kea/kea-dhcp4.conf" << EOF
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": ["${IFACE}"],
      "dhcp-socket-type": "raw"
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv"
    },
    "subnet4": [
      {
        "id": 1,
        "subnet": "${SUBNET_CIDR}",
        "pools": [
          { "pool": "${DHCP_START}-${DHCP_END}" }
        ],
        "valid-lifetime": 43200,
        "option-data": [
          { "name": "routers",             "data": "${LAN_IP}" },
          { "name": "domain-name-servers", "data": "${LAN_IP}" }
        ]
      }
    ],
    "loggers": [
      {
        "name": "kea-dhcp4",
        "output_options": [
          { "output": "/var/log/kea/kea-dhcp4.log" }
        ],
        "severity": "INFO"
      }
    ]
  }
}
EOF

# Seed DayShield core config so DHCP UI/API reflects installer defaults.
CORE_CFG_DIR="${TARGET}/etc/dayshield/config"
mkdir -p "$CORE_CFG_DIR"
cat > "${CORE_CFG_DIR}/config.json" << EOF
{
  "hostname": "${HOSTNAME}",
  "domain": null,
  "interfaces": [
    {
      "name": "${WAN_IFACE}",
      "description": "WAN",
      "addresses": [],
      "mtu": 1500,
      "enabled": true,
      "dhcp4": false,
      "dhcp6": false,
      "vlan": null,
      "wan_mode": "${WAN_TYPE}",
      "pppoe_username": "$([ "$WAN_TYPE" = "pppoe" ] && printf '%s' "$WAN_PPPOE_USER")",
      "pppoe_password": "$([ "$WAN_TYPE" = "pppoe" ] && printf '%s' "$WAN_PPPOE_PASS")",
      "gateway": null
    },
    {
      "name": "${IFACE}",
      "description": "LAN",
      "addresses": ["${LAN_IP}/${LAN_PREFIX}"],
      "mtu": 1500,
      "enabled": true,
      "dhcp4": false,
      "dhcp6": false,
      "vlan": null,
      "wan_mode": null,
      "pppoe_username": null,
      "pppoe_password": null,
      "gateway": null
    }
  ],
  "firewall_rules": [],
  "nat": null,
  "dns": null,
  "dhcp": {
    "enabled": true,
    "interface": "${IFACE}",
    "scopes": [
      {
        "id": "00000000-0000-0000-0000-000000000001",
        "subnet": "${SUBNET_CIDR}",
        "pool_start": "${DHCP_START}",
        "pool_end": "${DHCP_END}",
        "gateway": "${LAN_IP}",
        "dns_servers": ["${LAN_IP}"],
        "lease_seconds": 43200,
        "reservations": []
      }
    ]
  },
  "vpn_tunnels": [],
  "wireguard_interfaces": [],
  "acme": null,
  "crowdsec_policies": [],
  "suricata": null,
  "firewall_aliases": [],
  "dns_host_overrides": [],
  "dns_domain_overrides": [],
  "crowdsec": null,
  "notify": null,
  "system_settings": null,
  "ntp": null,
  "gateways": []
}
EOF

# ── Enable dayshield-core service ─────────────────────────────────
SYSTEMD_MULTI_USER="${TARGET}/etc/systemd/system/multi-user.target.wants"
mkdir -p "$SYSTEMD_MULTI_USER"

resolve_unit_path() {
  # Prefer custom units shipped in /etc over distro units.
  _svc="$1"
  if [ -f "${TARGET}/etc/systemd/system/${_svc}.service" ]; then
    printf '/etc/systemd/system/%s.service' "$_svc"
  elif [ -f "${TARGET}/lib/systemd/system/${_svc}.service" ]; then
    printf '/lib/systemd/system/%s.service' "$_svc"
  elif [ -f "${TARGET}/usr/lib/systemd/system/${_svc}.service" ]; then
    printf '/usr/lib/systemd/system/%s.service' "$_svc"
  else
    return 1
  fi
}

SERVICE_SRC="${TARGET}/usr/lib/systemd/system/dayshield-core.service"
SERVICE_LINK="${SYSTEMD_MULTI_USER}/dayshield-core.service"

if [ -f "$SERVICE_SRC" ]; then
  ln -sf "/usr/lib/systemd/system/dayshield-core.service" "$SERVICE_LINK" 2>/dev/null || true
fi

# Ensure systemd-resolved remains disabled in favour of unbound.
mkdir -p "${TARGET}/etc/systemd/system"
ln -sf /dev/null "${TARGET}/etc/systemd/system/systemd-resolved.service" 2>/dev/null || true

# Also enable required network services.
for svc in systemd-networkd kea-dhcp4-server nftables unbound; do
  if resolved_path=$(resolve_unit_path "$svc"); then
    ln -sf "${resolved_path}" \
       "${SYSTEMD_MULTI_USER}/${svc}.service" 2>/dev/null || true
  fi
done

# ── Write /etc/fstab ──────────────────────────────────────────────
DISK_NODE=$(printf '%s' "$DISK" | sed 's|^/dev/||')
EFI_PART="/dev/${DISK_NODE}2"
ROOT_PART="/dev/${DISK_NODE}3"
case "$DISK_NODE" in nvme*|mmcblk*) EFI_PART="/dev/${DISK_NODE}p2"; ROOT_PART="/dev/${DISK_NODE}p3" ;; esac

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || true)
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null || true)

{
  printf '# /etc/fstab - generated by DayShield installer\n'
  if [ -n "$ROOT_UUID" ]; then
    printf 'UUID=%s  /          ext4  defaults,noatime  0 1\n' "$ROOT_UUID"
  else
    printf '%s  /          ext4  defaults,noatime  0 1\n' "$ROOT_PART"
  fi
  if [ -n "$EFI_UUID" ]; then
    printf 'UUID=%s  /boot/efi  vfat  umask=0077        0 2\n' "$EFI_UUID"
  else
    printf '%s  /boot/efi  vfat  umask=0077        0 2\n' "$EFI_PART"
  fi
  printf 'tmpfs       /tmp       tmpfs defaults,nosuid,nodev  0 0\n'
} > "${TARGET}/etc/fstab"

printf '{"ok":true}\n'
