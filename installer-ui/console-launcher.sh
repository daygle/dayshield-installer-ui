#!/bin/sh

set -eu

dmesg -n 1 2>/dev/null || true
printf '\033c'

AUTO_LAUNCH="${INSTALLER_UI_AUTO_LAUNCH:-1}"
COMPACT_PREF="${INSTALLER_UI_COMPACT:-auto}"

supports_color() {
  if [ -n "${NO_COLOR:-}" ]; then
    return 1
  fi
  if [ ! -t 1 ]; then
    return 1
  fi
  if [ "${TERM:-}" = "dumb" ]; then
    return 1
  fi
  return 0
}

if supports_color; then
  C_RESET="$(printf '\033[0m')"
  C_BOLD="$(printf '\033[1m')"
  C_CYAN="$(printf '\033[36m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_RED="$(printf '\033[31m')"
else
  C_RESET=''
  C_BOLD=''
  C_CYAN=''
  C_GREEN=''
  C_YELLOW=''
  C_RED=''
fi

terminal_size() {
  if command -v tput >/dev/null 2>&1; then
    _cols="$(tput cols 2>/dev/null || true)"
    _rows="$(tput lines 2>/dev/null || true)"
  else
    _cols=""
    _rows=""
  fi

  if [ -z "${_cols}" ] || [ -z "${_rows}" ]; then
    _size="$(stty size 2>/dev/null || true)"
    if [ -n "${_size}" ]; then
      _rows="$(printf '%s' "${_size}" | awk '{print $1}')"
      _cols="$(printf '%s' "${_size}" | awk '{print $2}')"
    fi
  fi

  _rows="${_rows:-24}"
  _cols="${_cols:-80}"
  printf '%s %s\n' "${_rows}" "${_cols}"
}

is_compact_mode() {
  _pref="$(printf '%s' "${COMPACT_PREF}" | tr '[:upper:]' '[:lower:]')"
  case "${_pref}" in
    1|true|yes|on|compact)
      return 0
      ;;
    0|false|no|off|full)
      return 1
      ;;
  esac

  _size="$(terminal_size)"
  _rows="$(printf '%s' "${_size}" | awk '{print $1}')"
  _cols="$(printf '%s' "${_size}" | awk '{print $2}')"

  if [ "${_rows}" -lt 30 ] || [ "${_cols}" -lt 100 ]; then
    return 0
  fi
  return 1
}

should_auto_launch() {
  _mode="$(printf '%s' "${AUTO_LAUNCH}" | tr '[:upper:]' '[:lower:]')"
  case "${_mode}" in
    1|true|yes|on|auto)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

status_backend_text() {
  if is_listening_8443; then
    printf '%sUP%s' "${C_GREEN}" "${C_RESET}"
  else
    printf '%sDOWN%s' "${C_RED}" "${C_RESET}"
  fi
}

status_browser_text() {
  _browser="${1:-}"
  if [ -n "${_browser}" ]; then
    printf '%s%s%s' "${C_GREEN}" "${_browser}" "${C_RESET}"
  else
    printf '%snone%s' "${C_YELLOW}" "${C_RESET}"
  fi
}

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

detect_browser() {
  if command -v epiphany-browser >/dev/null 2>&1; then
    printf 'epiphany-browser\n'
    return 0
  fi
  if command -v firefox >/dev/null 2>&1; then
    printf 'firefox\n'
    return 0
  fi
  if command -v chromium >/dev/null 2>&1; then
    printf 'chromium\n'
    return 0
  fi
  if command -v surf >/dev/null 2>&1; then
    printf 'surf\n'
    return 0
  fi
  if command -v midori >/dev/null 2>&1; then
    printf 'midori\n'
    return 0
  fi
  return 1
}

launch_browser() {
  _url="$1"
  _browser="${2:-}"

  case "${_browser}" in
    epiphany-browser)
      epiphany-browser --application-mode="${_url}" >/dev/null 2>&1 || epiphany-browser "${_url}"
      ;;
    firefox)
      firefox --kiosk "${_url}" >/dev/null 2>&1 || firefox "${_url}"
      ;;
    chromium)
      chromium --kiosk --no-first-run --disable-translate "${_url}" >/dev/null 2>&1 || chromium "${_url}"
      ;;
    surf)
      surf "${_url}"
      ;;
    midori)
      midori "${_url}"
      ;;
    *)
      return 1
      ;;
  esac
}

show_splash() {
  _browser="${1:-}"
  _backend_state="$(status_backend_text)"
  _browser_state="$(status_browser_text "${_browser}")"
  _auto_state="disabled"
  if should_auto_launch; then
    _auto_state="enabled"
  fi

  printf "\n\n  ============================================================\n"
  printf "  %sDayShield Installer%s\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  printf "  ============================================================\n"
  printf "  Backend listener (8443): %s\n" "${_backend_state}"
  printf "  Local browser detected : %s\n" "${_browser_state}"
  printf "  Auto-launch local web  : %s\n" "${_auto_state}"
  printf "  Layout mode            : %s\n" "$(is_compact_mode && printf 'compact' || printf 'full')"
  printf "  ------------------------------------------------------------\n"
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

BROWSER=""
if BROWSER="$(detect_browser 2>/dev/null || true)"; then
  :
fi

show_splash "${BROWSER}"
if [ -n "${BROWSER}" ] && should_auto_launch; then
  printf "  Launching local web installer in kiosk mode...\n"
  printf "  Close the browser to return to this menu.\n\n"
  sleep 1
  launch_browser "${URL}" "${BROWSER}" || true
  printf '\033c'
fi

while true; do
  LAN_ADDRS="$({ ip -o -4 addr show scope global 2>/dev/null || true; } | awk '{print $2 " " $4}')"
  COMPACT_UI=0
  if is_compact_mode; then
    COMPACT_UI=1
  fi

  printf "\n\n  ============================================================\n"
  printf "  %sDayShield Installer - Console Access%s\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  printf "  ============================================================\n"

  if [ "${COMPACT_UI}" -eq 1 ]; then
    printf "  Mode: web installer preferred; command-line fallback available.\n"
    printf "  Backend 8443: %s\n\n" "$(status_backend_text)"
  else
    printf "  Two installation paths are available:\n"
    printf "    1) Web Installer from another computer (recommended)\n"
    printf "    2) Command-Line Installer on this console\n\n"
    printf "  Web Installer runs on port 8443 and needs a JS-capable browser.\n\n"
  fi

  if [ -n "$LAN_ADDRS" ]; then
    if [ "${COMPACT_UI}" -eq 0 ]; then
      printf "%s\n" "$LAN_ADDRS" | while read -r iface cidr; do
        ip=${cidr%%/*}
        printf "    %s  %s\n" "$iface" "$ip"
      done
      printf "\n"
      printf "  Web Installer URLs:\n"
    else
      printf "  URLs:\n"
    fi

    printf "%s\n" "$LAN_ADDRS" | while read -r iface cidr; do
      ip=${cidr%%/*}
      printf "    http://%s:8443/\n" "$ip"
    done
    printf "\n"
  else
    printf "  URL:\n"
    printf "    http://127.0.0.1:8443/\n"
    printf "\n"
  fi

  printf "  Command-Line Options:\n"
  printf "    [C] Command-line Installer\n"
  printf "    [S] Shell\n"
  printf "    [B] Reboot\n"
  printf "    [P] Poweroff\n"
  printf "    [R] Refresh\n"
  printf "    [Q] Quit\n\n"

  if [ -n "${BROWSER}" ]; then
    printf "  Local browser: %s\n" "${BROWSER}"
  else
    printf "  Local browser: none (remote web access only)\n"
  fi
  printf "  Enter choice (C/S/B/P/R/Q): "
  KEY=""
  read -r KEY 2>/dev/null || KEY=""
  case "$KEY" in
    [Cc])
      printf "  Launching command-line installer wizard...\n\n"

      if [ -f /installer-ui/dayshield-console ]; then
        if command -v bash >/dev/null 2>&1; then
          /bin/bash /installer-ui/dayshield-console || true
        elif command -v busybox >/dev/null 2>&1; then
          busybox ash /installer-ui/dayshield-console || true
        else
          /bin/sh /installer-ui/dayshield-console || true
        fi

        printf "\n  Command-line installer exited.\n"
      else
        printf "\n  ERROR: missing /installer-ui/dayshield-console\n"
      fi

      printf "  Press Enter to return to menu..."
      read -r _ 2>/dev/null || true
      printf '\033c'
      continue
      ;;
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
    [Bb])
      printf '  Reboot system now? [y/N]: '
      CONFIRM=""
      read -r CONFIRM 2>/dev/null || CONFIRM=""
      case "$CONFIRM" in
        [Yy]|[Yy][Ee][Ss])
          printf '  Rebooting...\n'
          if command -v systemctl >/dev/null 2>&1; then
            systemctl reboot >/dev/null 2>&1 || true
          fi
          if command -v reboot >/dev/null 2>&1; then
            reboot >/dev/null 2>&1 || true
          fi
          printf '  ERROR: reboot command failed.\n'
          printf '  Press Enter to return to menu...'
          read -r _ 2>/dev/null || true
          printf '\033c'
          continue
          ;;
        *)
          printf '  Reboot cancelled.\n'
          sleep 1
          printf '\033c'
          continue
          ;;
      esac
      ;;
    [Pp])
      printf '  Power off system now? [y/N]: '
      CONFIRM=""
      read -r CONFIRM 2>/dev/null || CONFIRM=""
      case "$CONFIRM" in
        [Yy]|[Yy][Ee][Ss])
          printf '  Powering off...\n'
          if command -v systemctl >/dev/null 2>&1; then
            systemctl poweroff >/dev/null 2>&1 || true
          fi
          if command -v poweroff >/dev/null 2>&1; then
            poweroff >/dev/null 2>&1 || true
          fi
          printf '  ERROR: poweroff command failed.\n'
          printf '  Press Enter to return to menu...'
          read -r _ 2>/dev/null || true
          printf '\033c'
          continue
          ;;
        *)
          printf '  Poweroff cancelled.\n'
          sleep 1
          printf '\033c'
          continue
          ;;
      esac
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
      printf '  Invalid choice. Please enter W, C, S, B, P, R, or Q.\n'
      sleep 1
      ;;
  esac
done