#!/bin/sh

set -eu

dmesg -n 1 2>/dev/null || true
printf '\033c'

is_listening_8443() {
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | grep -q ':8443 '
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | grep -q ':8443 '
    return $?
  fi
  return 1
}

start_emergency_httpd() {
  if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx httpd; then
    /bin/sh /installer-ui/start-httpd.sh >/dev/null 2>&1 &
    return 0
  fi
  # python3/python http.server cannot execute CGI scripts; fail explicitly so
  # the operator knows busybox httpd is required for CGI script execution.
  printf 'WARNING: busybox httpd not found; web installer CGI unavailable.\n' >&2
  return 1
}

# Ensure the web UI backend is actually up before showing access instructions.
if command -v systemctl >/dev/null 2>&1; then
  systemctl start installer-ui-web.service >/dev/null 2>&1 || true
fi

if ! is_listening_8443; then
  start_emergency_httpd || true
fi

URL="http://127.0.0.1:8443/"

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

while true; do
  LAN_ADDRS="$({ ip -o -4 addr show scope global 2>/dev/null || true; } | awk '{print $2 " " $4}')"

  printf "\n\n  ============================================================\n"
  printf "  DayShield Installer - Console Access\n"
  printf "  ============================================================\n"
  printf "  Two installation paths are available:\n"
  printf "    1) Web Installer from another computer (recommended)\n"
  printf "    2) Command-Line Installer on this console\n\n"
  printf "  Web Installer runs on port 8443 and needs a JS-capable browser.\n\n"

  if [ -n "$LAN_ADDRS" ]; then
    printf "%s\n" "$LAN_ADDRS" | while read -r iface cidr; do
      ip=${cidr%%/*}
      printf "    %s  %s\n" "$iface" "$ip"
    done
    printf "\n"

    printf "  Web Installer URLs:\n"
    printf "%s\n" "$LAN_ADDRS" | while read -r iface cidr; do
      ip=${cidr%%/*}
      printf "    http://%s:8443/\n" "$ip"
    done
    printf "\n"
  else
    printf "  Web Installer URL:\n"
    printf "    http://127.0.0.1:8443/\n"
    printf "\n"
  fi

  printf "  Command-Line Installer options:\n"
  printf "    [C] Start command-line installer wizard\n"
  printf "    [S] Open shell for diagnostics\n"
  printf "    [R] Refresh this screen\n"
  printf "    [Q] Quit this screen\n\n"

  printf "  Enter choice (C/S/R/Q): "
  KEY=""
  read -r KEY 2>/dev/null || KEY=""
  case "$KEY" in
    [Cc]) break ;;
    [Ss])
      printf '  Opening shell... (type "exit" to return to menu)\n\n'
      if command -v bash >/dev/null 2>&1; then
        /bin/bash --login || true
      else
        /bin/sh || true
      fi
      printf '\033c'
      continue
      ;;
    [Rr])
      printf '\033c'
      continue
      ;;
    [Qq]) exit 0 ;;
    "")
      # Empty input (Enter pressed alone): redisplay menu.
      printf '\033c'
      continue
      ;;
    *)
      printf '  Invalid choice. Please enter C, S, R, or Q.\n'
      sleep 1
      ;;
  esac
done

printf "  Launching command-line installer wizard...\n\n"
exec /installer-ui/dayshield-console