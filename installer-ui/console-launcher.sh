#!/bin/sh

set -eu

dmesg -n 1 2>/dev/null || true
printf '\033c'

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
  C_DIM="$(printf '\033[2m')"
  C_WHITE="$(printf '\033[97m')"
  C_CYAN="$(printf '\033[36m')"
  C_YELLOW="$(printf '\033[33m')"
  C_GREEN="$(printf '\033[32m')"
  C_RED="$(printf '\033[31m')"
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_WHITE=''
  C_CYAN=''
  C_YELLOW=''
  C_GREEN=''
  C_RED=''
fi

_WIDE_SEP="════════════════════════════════════════════════════════════"
_THIN_SEP="────────────────────────────────────────────────────────────"

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

status_backend_text() {
  if is_listening_8443; then
    printf '%sUP%s' "${C_GREEN}" "${C_RESET}"
  else
    printf '%sDOWN%s' "${C_RED}" "${C_RESET}"
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

normalize_yes_no() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

launch_interactive_shell() {
  # Force child shell I/O to the active console so it behaves interactively
  # even when this launcher is managed by systemd.
  if command -v bash >/dev/null 2>&1 && [ -x /bin/bash ]; then
    /bin/bash -i </dev/tty >/dev/tty 2>&1 || true
    return
  fi
  if command -v busybox >/dev/null 2>&1; then
    busybox ash </dev/tty >/dev/tty 2>&1 || true
    return
  fi
  /bin/sh </dev/tty >/dev/tty 2>&1 || true
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

while true; do
  printf '\033c'
  LAN4_ADDRS="$({ ip -o -4 addr show scope global 2>/dev/null || true; } | awk '{print $2 " " $4}')"
  LAN6_ADDRS="$({ ip -o -6 addr show scope global 2>/dev/null || true; } | awk '{print $2 " " $4}')"
  COMPACT_UI=0
  if is_compact_mode; then
    COMPACT_UI=1
  fi

  # Header
  printf "  %s%s%s\n" "${C_BOLD}" "${_WIDE_SEP}" "${C_RESET}"
  printf "  %sDayShield%s  %sWeb Installer%s\n" \
      "${C_BOLD}${C_WHITE}" "${C_RESET}" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  printf "  %s%s%s\n\n" "${C_BOLD}" "${_WIDE_SEP}" "${C_RESET}"

  if [ "${COMPACT_UI}" -eq 1 ]; then
    printf "  Mode: web installer preferred; command-line fallback available.\n"
    printf "  Backend 8443: %s\n\n" "$(status_backend_text)"
  else
    printf "  Two installation paths are available:\n"
    printf "    %s1)%s Web Installer from another computer %s(recommended)%s\n" \
        "${C_BOLD}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
    printf "    %s2)%s Command-Line Installer on this console\n\n" \
        "${C_BOLD}" "${C_RESET}"
    printf "  Web Installer runs on port 8443 and needs a JS-capable browser.\n"
    printf "  Backend: %s\n\n" "$(status_backend_text)"
  fi

  LAN4_COUNT="$(printf "%s\n" "$LAN4_ADDRS" | awk 'NF { count++ } END { print count + 0 }')"
  LAN6_COUNT="$(printf "%s\n" "$LAN6_ADDRS" | awk 'NF { count++ } END { print count + 0 }')"
  LAN_COUNT=$((LAN4_COUNT + LAN6_COUNT))

  if [ "${LAN_COUNT}" -gt 0 ]; then
    if [ "${LAN_COUNT}" -eq 1 ]; then
      WEB_URL_LABEL="Web Installer URL"
      URL_LABEL="URL"
    else
      WEB_URL_LABEL="Web Installer URLs"
      URL_LABEL="URLs"
    fi

    if [ "${COMPACT_UI}" -eq 0 ]; then
      printf "  %s%s%s\n" "${C_DIM}" "${_THIN_SEP}" "${C_RESET}"
      printf "  %s%-14s %s%s\n" "${C_DIM}" "Interface" "Address" "${C_RESET}"
      if [ -n "$LAN4_ADDRS" ]; then
        printf "%s\n" "$LAN4_ADDRS" | while read -r iface cidr; do
          ip=${cidr%%/*}
          printf "  %-14s %s\n" "$iface" "$ip"
        done
      fi
      if [ -n "$LAN6_ADDRS" ]; then
        printf "%s\n" "$LAN6_ADDRS" | while read -r iface cidr; do
          ip=${cidr%%/*}
          printf "  %-14s %s\n" "$iface" "$ip"
        done
      fi
      printf "  %s%s%s\n\n" "${C_DIM}" "${_THIN_SEP}" "${C_RESET}"
      printf "  %s%s:%s\n" "${C_BOLD}" "${WEB_URL_LABEL}" "${C_RESET}"
    else
      printf "  %s%s:%s\n" "${C_BOLD}" "${URL_LABEL}" "${C_RESET}"
    fi

    if [ -n "$LAN4_ADDRS" ]; then
      printf "%s\n" "$LAN4_ADDRS" | while read -r iface cidr; do
        ip=${cidr%%/*}
        printf "    %s%shttp://%s:8443/%s\n" "${C_BOLD}" "${C_CYAN}" "$ip" "${C_RESET}"
      done
    fi
    if [ -n "$LAN6_ADDRS" ]; then
      printf "%s\n" "$LAN6_ADDRS" | while read -r iface cidr; do
        ip=${cidr%%/*}
        printf "    %s%shttp://[%s]:8443/%s\n" "${C_BOLD}" "${C_CYAN}" "$ip" "${C_RESET}"
      done
    fi
    printf "\n"
  else
    printf "  %sURL:%s\n" "${C_BOLD}" "${C_RESET}"
    printf "    %s%shttp://127.0.0.1:8443/%s\n\n" "${C_BOLD}" "${C_CYAN}" "${C_RESET}"
  fi

  printf "  %s%s%s\n\n" "${C_BOLD}" "${_WIDE_SEP}" "${C_RESET}"

  printf "  %sActions%s\n" "${C_BOLD}" "${C_RESET}"
  printf "  %s%s%s\n" "${C_DIM}" "${_THIN_SEP}" "${C_RESET}"
  printf "   %s%s[1]%s  Command-line Installer\n" "${C_BOLD}" "${C_YELLOW}" "${C_RESET}"
  printf "   %s%s[2]%s  Shell\n" "${C_BOLD}" "${C_YELLOW}" "${C_RESET}"
  printf "   %s%s[3]%s  Reboot\n" "${C_BOLD}" "${C_YELLOW}" "${C_RESET}"
  printf "   %s%s[4]%s  Poweroff\n" "${C_BOLD}" "${C_YELLOW}" "${C_RESET}"
  printf "   %s%s[5]%s  Refresh\n" "${C_BOLD}" "${C_YELLOW}" "${C_RESET}"
  printf "   %s%s[0]%s  Quit\n" "${C_BOLD}" "${C_YELLOW}" "${C_RESET}"
  printf "  %s%s%s\n\n" "${C_DIM}" "${_THIN_SEP}" "${C_RESET}"

  printf "%s  Select option: %s" "${C_BOLD}" "${C_RESET}"
  KEY=""
  read -r KEY 2>/dev/null || KEY=""
  case "$KEY" in
    1)
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
        printf "\n  ERROR: Console installer not found.\n"
      fi

      printf "  Press Enter to return to menu..."
      read -r _ 2>/dev/null || true
      continue
      ;;
    2)
      printf '  Opening shell... (type "exit" to return to menu)\n\n'
      launch_interactive_shell
      continue
      ;;
    3)
      printf '  Reboot system now? [y/N]: '
      CONFIRM=""
      read -r CONFIRM 2>/dev/null || CONFIRM=""
      CONFIRM="$(normalize_yes_no "$CONFIRM")"
      case "$CONFIRM" in
        y|yes)
          printf '  Rebooting...\n'
          rebooted=false
          if command -v systemctl >/dev/null 2>&1; then
            systemctl reboot >/dev/null 2>&1 && rebooted=true || true
          fi
          if [ "$rebooted" != true ] && command -v reboot >/dev/null 2>&1; then
            reboot >/dev/null 2>&1 && rebooted=true || true
          fi
          if [ "$rebooted" != true ] && command -v shutdown >/dev/null 2>&1; then
            shutdown -r now >/dev/null 2>&1 && rebooted=true || true
          fi
          if [ "$rebooted" != true ]; then
            printf '  ERROR: reboot command failed.\n'
            printf '  Press Enter to return to menu...'
            read -r _ 2>/dev/null || true
          fi
          continue
          ;;
        *)
          printf '  Reboot cancelled.\n'
          sleep 1
          continue
          ;;
      esac
      ;;
    4)
      printf '  Power off system now? [y/N]: '
      CONFIRM=""
      read -r CONFIRM 2>/dev/null || CONFIRM=""
      CONFIRM="$(normalize_yes_no "$CONFIRM")"
      case "$CONFIRM" in
        y|yes)
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
          continue
          ;;
        *)
          printf '  Poweroff cancelled.\n'
          sleep 1
          continue
          ;;
      esac
      ;;
    5)
      continue
      ;;
    "")      # Empty input (Enter pressed alone): redisplay menu.
      continue
      ;;
    0)
      printf '  Exiting.\n'
      exit 0
      ;;
    *)
      printf '  Invalid choice.\n'
      sleep 1
      ;;
  esac
done