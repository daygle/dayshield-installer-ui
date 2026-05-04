#!/bin/sh

set -eu

dmesg -n 1 2>/dev/null || true
printf '\033c'

is_listening_8080() {
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | grep -q ':8080 '
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | grep -q ':8080 '
    return $?
  fi
  return 1
}

start_emergency_httpd() {
  if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx httpd; then
    if busybox httpd --help 2>&1 | grep -q -- "-t"; then
      busybox httpd -f -p 0.0.0.0:8080 -h /installer-ui -c /installer-ui/httpd.conf -t 1800 &
    else
      busybox httpd -f -p 0.0.0.0:8080 -h /installer-ui -c /installer-ui/httpd.conf &
    fi
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -m http.server 8080 --bind 0.0.0.0 --directory /installer-ui >/dev/null 2>&1 &
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    (cd /installer-ui && python -m SimpleHTTPServer 8080 >/dev/null 2>&1 &) 
    return 0
  fi
  return 1
}

# Ensure the web UI backend is actually up before showing access instructions.
if command -v systemctl >/dev/null 2>&1; then
  systemctl start installer-ui-web.service >/dev/null 2>&1 || true
fi

if ! is_listening_8080; then
  start_emergency_httpd || true
fi

URL="http://127.0.0.1:8080/"
IPS="$({ ip -o -4 addr show scope global 2>/dev/null || true; } | grep -oE "inet [0-9.]+" | cut -d' ' -f2 | tr '\n' ' ')"

if command -v epiphany-browser >/dev/null 2>&1; then
  exec epiphany-browser "$URL"
elif command -v firefox >/dev/null 2>&1; then
  exec firefox "$URL"
elif command -v chromium >/dev/null 2>&1; then
  exec chromium "$URL"
elif command -v surf >/dev/null 2>&1; then
  exec surf "$URL"
elif command -v midori >/dev/null 2>&1; then
  exec midori "$URL"
fi

printf "\n\n  ============================================================\n"
printf "  DayShield Installer - Console Access\n"
printf "  ============================================================\n"
printf "  Two installation paths are available:\n"
printf "    1) Web Installer from another computer (recommended)\n"
printf "    2) Command-Line Installer on this console\n\n"
printf "  Web Installer runs on port 8080 and needs a JS-capable browser.\n\n"

if [ -n "$IPS" ]; then
  printf "  Use these Web Installer URLs from another computer:\n"
  for ip in $IPS; do
    printf "    http://%s:8080/\n" "$ip"
  done
  printf "\n"
  printf "  Direct-connect fallback URL:\n"
  printf "    http://192.168.50.1:8080/\n"
  printf "\n"
else
  printf "  No LAN IPv4 address detected yet for remote access.\n"
  printf "  Fallback direct-connect address:\n"
  printf "    http://192.168.50.1:8080/\n"
  printf "  Windows IPv4 settings: 192.168.50.2 / 255.255.255.0\n\n"
fi

printf "  Command-Line Installer options:\n"
printf "    [C] Start command-line installer wizard\n"
printf "    [R] Refresh this screen\n"
printf "    [Q] Quit this screen\n\n"

printf "  Launching command-line installer wizard...\n\n"
exec /usr/local/bin/dayshield-console