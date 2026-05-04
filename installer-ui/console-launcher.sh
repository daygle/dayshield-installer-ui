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
printf "  Web UI is running on port 8080 and needs a JS-capable browser.\n\n"

if [ -n "$IPS" ]; then
  printf "  Remote access URLs:\n"
  for ip in $IPS; do
    printf "    http://%s:8080/\n" "$ip"
  done
  printf "\n"
else
  printf "  No LAN IPv4 address detected yet.\n"
  printf "  Fallback direct-connect address:\n"
  printf "    http://192.168.50.1:8080/\n"
  printf "  Windows IPv4 settings: 192.168.50.2 / 255.255.255.0\n\n"
fi

printf "  Local rescue options:\n"
printf "    [R] Run console fallback wizard\n"
printf "    [Q] Quit this screen\n\n"

while :; do
  printf "  Select [R/Q]: "
  IFS= read -r choice || choice=""
  case "$choice" in
    r|R) exec /usr/local/bin/dayshield-console ;;
    q|Q) exit 0 ;;
    *) printf "  Invalid choice. Type R or Q.\n" ;;
  esac
done