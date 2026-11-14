# shellcheck shell=bash
# retrobox-labwc login hook, sourced from your login profile (~/.bash_profile
# or ~/.profile) by the block `retrobox-labwc install` adds there.
#
# On the gaming TTY (retrobox.ini, [advanced] labwc_tty) it runs the labwc
# session in the foreground; anywhere else it does nothing. When the session
# ends you are left at the shell prompt (log out for a fresh autologin).
#
# Ctrl+C while the session is starting brings you back to the prompt.

__retrobox_labwc_autostart() {
  local root gaming_tty current_tty status

  root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd -P)" || return 0

  # Cheap checks first: this runs in every login shell.
  [[ $- == *i* ]] || return 0
  current_tty="$(tty 2>/dev/null)" || return 0
  [[ "${current_tty}" == /dev/tty[0-9]* ]] || return 0
  [[ -r "${root}/libexec/retrobox-labwc-common.sh" ]] || return 0

  # shellcheck source=libexec/retrobox-labwc-common.sh
  source "${root}/libexec/retrobox-labwc-common.sh" || return 0

  gaming_tty="$(get_gaming_tty 2>/dev/null)" || return 0
  [[ "${current_tty}" == "/dev/tty${gaming_tty}" ]] || return 0

  # Already inside a compositor (or re-sourcing the profile from a
  # terminal within the session): don't start a second one.
  [[ -n "${WAYLAND_DISPLAY:-}" ]] && return 0
  pgrep -u "$(id -u)" -x labwc >/dev/null 2>&1 && return 0

  "${root}/bin/retrobox-labwc-session"
  status=$?
  echo "retrobox-labwc: session ended (status ${status}); see ${XDG_STATE_HOME:-${HOME}/.local/state}/retrobox/logs/labwc-session.log"
}

__retrobox_labwc_autostart
unset -f __retrobox_labwc_autostart
