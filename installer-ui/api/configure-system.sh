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

QS="${QUERY_STRING:-}"
if [ "${REQUEST_METHOD:-}" = "POST" ] && [ -n "${CONTENT_LENGTH:-}" ]; then
  # Validate CONTENT_LENGTH is a non-negative integer and cap at 65536 (64 KiB)
  # to prevent a DoS via an unbounded byte-by-byte dd read.  Reject malformed
  # values rather than silently treating them as zero.
  _CL="${CONTENT_LENGTH}"
  case "$_CL" in
    *[!0-9]*) printf '{"error":"Invalid Content-Length"}\n'; exit 1 ;;
  esac
  if [ "$_CL" -gt 65536 ]; then _CL=65536; fi
  POST_DATA=$(dd bs=1 count="$_CL" 2>/dev/null || true)
  if [ -n "$POST_DATA" ]; then
    if [ -n "$QS" ]; then
      QS="${QS}&${POST_DATA}"
    else
      QS="$POST_DATA"
    fi
  fi
fi

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
LAN_DHCP_ENABLE=$(parse_param "$QS" "lan_dhcp_enable")
DHCP_START=$(parse_param "$QS" "dhcp_start")
DHCP_END=$(parse_param "$QS" "dhcp_end")

DISK=$(trim_ws "$DISK")
HOSTNAME=$(trim_ws "$HOSTNAME")
IFACE=$(trim_ws "$IFACE")
WAN_IFACE=$(trim_ws "$WAN_IFACE")
WAN_TYPE=$(trim_ws "$WAN_TYPE")
LAN_IP=$(trim_ws "$LAN_IP")
LAN_PREFIX=$(trim_ws "$LAN_PREFIX")
LAN_DHCP_ENABLE=$(trim_ws "$LAN_DHCP_ENABLE")
DHCP_START=$(trim_ws "$DHCP_START")
DHCP_END=$(trim_ws "$DHCP_END")

[ -n "$LAN_IP" ] || LAN_IP="192.168.1.1"
[ -n "$LAN_PREFIX" ] || LAN_PREFIX="24"
[ -n "$LAN_DHCP_ENABLE" ] || LAN_DHCP_ENABLE="yes"
[ -n "$DHCP_START" ] || DHCP_START="192.168.1.100"
[ -n "$DHCP_END" ] || DHCP_END="192.168.1.199"

# ── Validate ──────────────────────────────────────────────────────
if [ -z "$DISK" ]; then
  printf '{"error":"Missing required parameter: disk"}\n'; exit 1
fi
# Strip /dev/ prefix then enforce a strict device-name whitelist to prevent
# path traversal or unexpected device paths.
DISK=$(printf '%s' "$DISK" | sed 's|^/dev/||')
if ! printf '%s' "$DISK" | grep -Eq '^[a-zA-Z0-9]+$'; then
  printf '{"error":"Invalid disk name"}\n'; exit 1
fi
if [ -z "$HOSTNAME" ]; then
  printf '{"error":"Missing required parameter: hostname"}\n'; exit 1
fi
if [ -z "$PASSWORD" ]; then
  printf '{"error":"Missing required parameter: password"}\n'; exit 1
fi
_pwlen=$(printf '%s' "$PASSWORD" | wc -c)
if [ "$_pwlen" -gt 128 ]; then
  printf '{"error":"Password must be 128 characters or fewer"}\n'; exit 1
fi
if [ -z "$IFACE" ]; then
  printf '{"error":"Missing required parameter: iface"}\n'; exit 1
fi
if [ -z "$WAN_IFACE" ]; then
  printf '{"error":"Missing required parameter: wan_iface"}\n'; exit 1
fi
if [ -z "$IFACE" ] || [ -z "$WAN_IFACE" ]; then
  printf '{"error":"Invalid interface selection"}\n'; exit 1
fi
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

if ! printf '%s' "$LAN_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  printf '{"error":"Invalid lan_ip"}\n'; exit 1
fi
if ! printf '%s' "$LAN_PREFIX" | grep -Eq '^[0-9]{1,2}$' || [ "$LAN_PREFIX" -lt 1 ] || [ "$LAN_PREFIX" -gt 32 ]; then
  printf '{"error":"Invalid lan_prefix"}\n'; exit 1
fi
if [ "$LAN_DHCP_ENABLE" != "yes" ] && [ "$LAN_DHCP_ENABLE" != "no" ]; then
  printf '{"error":"Invalid lan_dhcp_enable: expected yes or no"}\n'; exit 1
fi
if ! printf '%s' "$DHCP_START" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  printf '{"error":"Invalid dhcp_start"}\n'; exit 1
fi
if ! printf '%s' "$DHCP_END" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  printf '{"error":"Invalid dhcp_end"}\n'; exit 1
fi

SUBNET_CIDR="${LAN_IP}/${LAN_PREFIX}"
DHCP_ENABLED_JSON="false"
if [ "$LAN_DHCP_ENABLE" = "yes" ]; then
  DHCP_ENABLED_JSON="true"
fi

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
# Prefer using the installed system's chpasswd for the target rootfs when available.
# Lock any existing root password before applying the new one.
if chroot "$TARGET" command -v passwd >/dev/null 2>&1; then
  chroot "$TARGET" passwd -l root >/dev/null 2>&1 || true
fi
if printf '%s' "$PASSWORD" | grep -q ':'; then
  USE_CHPASSWD=0
elif chroot "$TARGET" command -v chpasswd >/dev/null 2>&1; then
  if ! printf '%s\n' "root:${PASSWORD}" | chroot "$TARGET" chpasswd >/dev/null 2>&1; then
    USE_CHPASSWD=0
  else
    USE_CHPASSWD=1
  fi
else
  USE_CHPASSWD=0
fi

if [ "$USE_CHPASSWD" -eq 0 ]; then
  # Fall back to deterministic host-side hashing and direct shadow replacement.
  if command -v openssl >/dev/null 2>&1; then
    HASH=$(openssl passwd -6 -- "$PASSWORD" 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    HASH=$(python3 - "$PASSWORD" 2>/dev/null << 'PYEOF'
import sys, hashlib, secrets

def _sha512crypt(pwd, salt, rounds=5000):
    p = pwd.encode('utf-8')
    s = salt.encode('utf-8')
    dB = hashlib.sha512(p + s + p).digest()
    tmp = p + s
    pl = len(p)
    i = pl
    while i > 0:
        tmp += dB[:min(i, 64)]
        i -= 64
    i = pl
    while i > 0:
        tmp += (dB if i & 1 else p)
        i >>= 1
    dA = hashlib.sha512(tmp).digest()
    dP = hashlib.sha512(p * pl).digest()
    pStr = b''
    i = pl
    while i > 0:
        pStr += dP[:min(i, 64)]
        i -= 64
    dS = hashlib.sha512(s * (16 + dA[0])).digest()
    sStr = b''
    i = len(s)
    while i > 0:
        sStr += dS[:min(i, 64)]
        i -= 64
    C = dA
    for i in range(rounds):
        t = (pStr if i % 2 else C)
        if i % 3:
            t += sStr
        if i % 7:
            t += pStr
        t += (C if i % 2 else pStr)
        C = hashlib.sha512(t).digest()
    return C

_B64CHARS = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'

def _b64(v, n):
    r = ''
    while n > 0:
        r += _B64CHARS[v & 0x3f]
        v >>= 6
        n -= 1
    return r

def sha512crypt(pwd):
    salt = ''.join(secrets.choice(_B64CHARS) for _ in range(16))
    C = _sha512crypt(pwd, salt)
    def t64(a, b, c, n): return _b64((a << 16) | (b << 8) | c, n)
    h = (t64(C[0],C[21],C[42],4)+t64(C[22],C[43],C[1],4)+t64(C[44],C[2],C[23],4)+
         t64(C[3],C[24],C[45],4)+t64(C[25],C[46],C[4],4)+t64(C[47],C[5],C[26],4)+
         t64(C[6],C[27],C[48],4)+t64(C[28],C[49],C[7],4)+t64(C[50],C[8],C[29],4)+
         t64(C[9],C[30],C[51],4)+t64(C[31],C[52],C[10],4)+t64(C[53],C[11],C[32],4)+
         t64(C[12],C[33],C[54],4)+t64(C[34],C[55],C[13],4)+t64(C[56],C[14],C[35],4)+
         t64(C[15],C[36],C[57],4)+t64(C[37],C[58],C[16],4)+t64(C[59],C[17],C[38],4)+
         t64(C[18],C[39],C[60],4)+t64(C[40],C[61],C[19],4)+t64(C[62],C[20],C[41],4)+
         _b64(C[63], 2))
    return '$6${}${}'.format(salt, h)

password = sys.argv[1]
try:
    import crypt
    print(crypt.crypt(password, crypt.mksalt(crypt.METHOD_SHA512)))
except (ImportError, AttributeError):
    print(sha512crypt(password))
PYEOF
)
  else
    printf '{"error":"Cannot hash password: neither openssl nor python3 found"}\n'; exit 1
  fi

  if [ -z "$HASH" ]; then
    printf '{"error":"Password hashing failed"}\n'; exit 1
  fi

if [ ! -f "${TARGET}/etc/shadow" ]; then
  printf '{"error":"/etc/shadow not found in target — the rootfs may not have been installed correctly or the shadow file is absent from the image"}\n'; exit 1
fi
ROOT_COUNT=$(awk -F: '$1=="root"{c++} END{print c+0}' "${TARGET}/etc/shadow")
if [ "$ROOT_COUNT" -eq 0 ]; then
  printf '{"error":"No root entry found in /etc/shadow — cannot set root password"}\n'; exit 1
fi
if [ "$ROOT_COUNT" -gt 1 ]; then
  printf '{"error":"Invalid /etc/shadow: multiple root entries found"}\n'; exit 1
fi
SHADOW_ESCAPED=$(printf '%s' "$HASH" | sed 's|[&/\\]|\\&|g')
sed -i "s|^root:[^:]*:|root:${SHADOW_ESCAPED}:|" "${TARGET}/etc/shadow"
HASH_IN_SHADOW=$(grep '^root:' "${TARGET}/etc/shadow" | head -n1 | cut -d: -f2)
if [ "$HASH_IN_SHADOW" != "$HASH" ]; then
  printf '{"error":"Password was not applied — root entry in /etc/shadow was not updated"}\n'; exit 1
fi
fi

# Ensure SSH accepts root password login for first access after install.
if [ -f "${TARGET}/etc/ssh/sshd_config" ]; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${TARGET}/etc/ssh/sshd_config"
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "${TARGET}/etc/ssh/sshd_config"
fi

# ── Create DayShield admin.json (management UI credentials) ──────
# dayshield-core uses its own Argon2id auth store — separate from Linux root.
# Use the binary in the target rootfs to hash and write the credentials so
# the same code/parameters are used at install time and at runtime.
if chroot "$TARGET" /usr/local/sbin/dayshield-core init-admin "$PASSWORD" >/dev/null 2>&1; then
  chmod 600 "${TARGET}/etc/dayshield/admin.json" 2>/dev/null || true
else
  printf '{"error":"Failed to initialise DayShield admin credentials — dayshield-core init-admin failed"}\n'; exit 1
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
LAN_DHCP_ENABLE=${LAN_DHCP_ENABLE}
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
# Remove generic installer placeholders to avoid match/order conflicts with
# the WAN/LAN config we are about to write.
rm -f "${NETWORKD_DIR}/10-dayshield-eth.network"
rm -f "${NETWORKD_DIR}/10-dayshield-en.network"
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
# Fallback: if the anchor file is still absent/empty (no network available in
# the install chroot), use the static trust anchor from dns-root-data.
if [ ! -s "${TARGET}/var/lib/unbound/root.key" ]; then
    if [ -f "/usr/share/dns/root.key" ]; then
        cp /usr/share/dns/root.key "${TARGET}/var/lib/unbound/root.key" 2>/dev/null || true
    elif [ -f "${TARGET}/usr/share/dns/root.key" ]; then
        cp "${TARGET}/usr/share/dns/root.key" "${TARGET}/var/lib/unbound/root.key" 2>/dev/null || true
    fi
fi
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
  hide-identity: yes
  hide-version: yes

  cache-min-ttl: 300
  cache-max-ttl: 86400

  verbosity: 1
  log-queries: no

  num-threads: 2
  rrset-cache-size: 256m
  msg-cache-size: 128m

  prefetch: yes

  private-address: 10.0.0.0/8
  private-address: 172.16.0.0/12
  private-address: 192.168.0.0/16
  private-address: 100.64.0.0/10

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
# Generate UUIDs for seeded default firewall rules.
_lan_rule_uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')"
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
  "firewall_rules": [
    {
      "id": "${_lan_rule_uuid}",
      "description": "Default: allow all from LAN",
      "priority": 10,
      "source": null,
      "destination": null,
      "protocol": null,
      "source_port": null,
      "destination_port": null,
      "action": "accept",
      "interface": "${IFACE}",
      "log": false
    }
  ],
  "nat": null,
  "dns": null,
  "dhcp": {
    "enabled": ${DHCP_ENABLED_JSON},
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

chmod 600 "${CORE_CFG_DIR}/config.json"

# ── Update Suricata WAN interface ─────────────────────────────────
SURICATA_YAML="${TARGET}/etc/suricata/suricata.yaml"
if [ -f "$SURICATA_YAML" ]; then
  # Only replace lines with exactly two leading spaces (af-packet / pcap
  # capture entries).  A broader pattern would corrupt app-layer protocol
  # blocks that also contain an 'interface:' key at deeper indentation.
  sed -i "s/^  - interface: .*$/  - interface: ${WAN_IFACE}/" "$SURICATA_YAML"
fi
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

DAYSHIELD_SVC_WARNING=""
if resolved_path=$(resolve_unit_path "dayshield"); then
  ln -sf "${resolved_path}" \
     "${SYSTEMD_MULTI_USER}/dayshield.service" 2>/dev/null || true
else
  DAYSHIELD_SVC_WARNING="dayshield.service not found in target rootfs; service will not start on boot"
fi

# Ensure systemd-resolved remains disabled in favour of unbound.
mkdir -p "${TARGET}/etc/systemd/system"
ln -sf /dev/null "${TARGET}/etc/systemd/system/systemd-resolved.service" 2>/dev/null || true

# Point resolv.conf at the local Unbound resolver.
printf 'nameserver 127.0.0.1\n' > "${TARGET}/etc/resolv.conf"
chmod 644 "${TARGET}/etc/resolv.conf"

# Also enable required network services.
for svc in systemd-networkd kea-dhcp4-server nftables unbound; do
  if resolved_path=$(resolve_unit_path "$svc"); then
    ln -sf "${resolved_path}" \
       "${SYSTEMD_MULTI_USER}/${svc}.service" 2>/dev/null || true
  fi
done

# Ensure installed systems present a standard tty1 login prompt.
# The ISO injects installer console units for live boot; disable them on target.
for unit in installer-ui.service installer-ui-web.service console-wizard.service; do
  rm -f "${SYSTEMD_MULTI_USER}/${unit}" 2>/dev/null || true
done

# Restore/ensure local getty targets are enabled for console access.
mkdir -p "${TARGET}/etc/systemd/system/getty.target.wants"
if [ -f "${TARGET}/lib/systemd/system/getty@.service" ]; then
  ln -sf /lib/systemd/system/getty@.service \
    "${TARGET}/etc/systemd/system/getty.target.wants/getty@tty1.service"
elif [ -f "${TARGET}/usr/lib/systemd/system/getty@.service" ]; then
  ln -sf /usr/lib/systemd/system/getty@.service \
    "${TARGET}/etc/systemd/system/getty.target.wants/getty@tty1.service"
fi

# Remove any stale masks that could block console logins.
rm -f "${TARGET}/etc/systemd/system/getty@tty1.service" 2>/dev/null || true

# ── Write /etc/fstab ──────────────────────────────────────────────
DISK_NODE="$DISK"
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

if [ -n "${DAYSHIELD_SVC_WARNING}" ]; then
  WARN_JSON=$(printf '%s' "${DAYSHIELD_SVC_WARNING}" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"ok":true,"warning":"%s"}\n' "${WARN_JSON}"
else
  printf '{"ok":true}\n'
fi
