#!/bin/sh

set -eu

dmesg -n 1 2>/dev/null || true
printf '\033c'

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

while :; do
  printf "  Select [C/R/Q]: "
  IFS= read -r choice || choice=""
  case "$choice" in
    c|C) exec /usr/local/bin/dayshield-console ;;
    r|R) exec /bin/sh /installer-ui/console-launcher.sh ;;
    q|Q) exit 0 ;;
    *) printf "  Invalid choice. Type C, R, or Q.\n" ;;
  esac
done