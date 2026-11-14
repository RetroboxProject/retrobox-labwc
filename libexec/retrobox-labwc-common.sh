#!/usr/bin/env bash
# Shared constants and helpers for the labwc gaming-session scripts.
# This file is meant to be sourced, never executed directly.
#
# No path is hardcoded:
#   * RETROBOX_LABWC_DIR is this tree's own root, derived from this file's
#     real location (<dir>/libexec/ -> <dir>): the git checkout, or the copy
#     `retrobox-labwc install` made in ~/.local/share/retrobox-labwc.
#   * RETROBOX_ROOT is the retrobox-core install, found (in this order) from
#     $RETROBOX_ROOT and the `retrobox` command on PATH. It may stay empty:
#     only what really needs retrobox-core (starting it) fails without it.
#
# retrobox.ini is read here with the same layering as retrobox-core
# (/etc/retrobox, then ~/.config/retrobox, each followed by its
# retrobox.ini.d/*.ini drop-ins; the last value wins), so neither Python nor
# retrobox-core is needed to know the gaming TTY.
#
# Safe to source more than once and from an interactive shell (the login
# hook): no "readonly", no "exit", every helper returns.

if [[ -n "${RETROBOX_LABWC_COMMON_SOURCED:-}" ]]; then
  # shellcheck disable=SC2317  # "|| true" only matters if executed by mistake
  return 0 2>/dev/null || true
fi
RETROBOX_LABWC_COMMON_SOURCED=1

# (used by the scripts that source this file)
# shellcheck disable=SC2034
RETROBOX_LABWC_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." &>/dev/null && pwd -P)"

# labwc's own configuration directory for the gaming session (labwc -C):
# kept apart from ~/.config/labwc so it never touches a labwc setup of yours.
RETROBOX_LABWC_CONFIG_DIR="${RETROBOX_LABWC_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/retrobox-labwc}"

# Where the system keyboard is configured (keyboard-configuration on Debian).
RETROBOX_KEYBOARD_FILE="${RETROBOX_KEYBOARD_FILE:-/etc/default/keyboard}"

# Prints the retrobox-core install root, or returns 1.
find_retrobox_root() {
  local candidate cmd

  candidate="${RETROBOX_ROOT:-}"
  if [[ -n "${candidate}" && -x "${candidate}/bin/retrobox" ]]; then
    (cd -- "${candidate}" && pwd -P)
    return 0
  fi

  cmd="$(command -v retrobox 2>/dev/null)" || return 1
  candidate="$(dirname -- "$(dirname -- "$(readlink -f -- "${cmd}")")")"
  [[ -x "${candidate}/bin/retrobox" ]] || return 1
  printf '%s\n' "${candidate}"
}

# Prints the retrobox.ini files, lowest priority first.
retrobox_ini_files() {
  local sysconf="${RETROBOX_SYSCONFDIR:-/etc/retrobox}"
  local config="${RETROBOX_CONFIGDIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/retrobox}"
  local layer dropin

  for layer in "${sysconf}" "${config}"; do
    [[ -r "${layer}/retrobox.ini" ]] && printf '%s\n' "${layer}/retrobox.ini"
    for dropin in "${layer}"/retrobox.ini.d/*.ini; do
      [[ -r "${dropin}" ]] && printf '%s\n' "${dropin}"
    done
  done
}

# Prints the value of "key" under "[section]" in one INI file.
# Returns 1 (prints nothing) if the file, section or key is missing.
read_ini_value() {
  local file="$1"
  local section="$2"
  local key="$3"

  [[ -r "${file}" ]] || return 1

  awk -v section="${section}" -v key="${key}" '
    /^[[:space:]]*[#;]/ { next }
    /^[[:space:]]*\[/ {
      name = $0
      gsub(/^[[:space:]]*\[[[:space:]]*|[[:space:]]*\][[:space:]]*$/, "", name)
      in_section = (name == section)
      next
    }
    in_section {
      eq = index($0, "=")
      if (eq == 0) { next }
      name = substr($0, 1, eq - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != key) { next }
      value = substr($0, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      found = 1
      exit
    }
    END { exit !found }
  ' "${file}"
}

# Prints the merged value of "key" under "[section]" across every
# retrobox.ini layer (the last one that sets it wins). Returns 1 if unset.
get_retrobox_setting() {
  local section="$1"
  local key="$2"
  local file value result="" found=1

  while IFS= read -r file; do
    if value="$(read_ini_value "${file}" "${section}" "${key}")"; then
      result="${value}"
      found=0
    fi
  done < <(retrobox_ini_files)

  ((found == 0)) || return 1
  printf '%s\n' "${result}"
}

# True if $1 is a valid VT number (1-12).
is_valid_tty() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && ((10#${1} >= 1 && 10#${1} <= 12))
}

# Prints the gaming TTY: RETROBOX_LABWC_TTY (set by the systemd service),
# else retrobox.ini, [advanced] labwc_tty.
# Returns 1 with a message on stderr if it is missing or out of range.
get_gaming_tty() {
  local tty="${RETROBOX_LABWC_TTY:-}"

  [[ -n "${tty}" ]] || tty="$(get_retrobox_setting advanced labwc_tty)" || {
    echo "error: missing [advanced] labwc_tty in retrobox.ini" \
      "(~/.config/retrobox/retrobox.ini or /etc/retrobox/retrobox.ini)" >&2
    return 1
  }

  if ! is_valid_tty "${tty}"; then
    echo "error: labwc_tty must be an integer between 1 and 12, got '${tty}'" >&2
    return 1
  fi

  printf '%s\n' "$((10#${tty}))"
}

# Prints the VT number this process is attached to, or nothing.
get_current_tty() {
  local dev
  dev="$(tty 2>/dev/null)" || return 1
  [[ "${dev}" =~ ^/dev/tty([0-9]+)$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# ---------------------------------------------------------------- keyboard
# The session always uses the keyboard the system has. Nothing about it is
# copied into the labwc config: it is read again every time the session
# starts, so changing it system-wide (on Debian: dpkg-reconfigure
# keyboard-configuration) and restarting the session (Win+Shift+R) is enough.

# Prints the value of KEY in a shell-style KEY="value" file (the last one).
kb_file_value() {
  local file="$1"
  local key="$2"

  sed -n -E "s/^[[:space:]]*${key}=[\"']?([^\"']*)[\"']?[[:space:]]*(#.*)?\$/\\1/p" "${file}" | tail -n1
}

# Prints the value of "X11 <field>" in `localectl status` ("n/a" is empty).
kb_localectl_value() {
  local status="$1"
  local field="$2"
  local value

  value="$(awk -F': *' -v field="X11 ${field}" '$0 ~ "^[[:space:]]*" field ":" {print $2; exit}' <<<"${status}")"
  [[ "${value}" == "n/a" ]] || printf '%s' "${value}"
}

# Sets XKB_MODEL, XKB_LAYOUT, XKB_VARIANT, XKB_OPTIONS and KB_SOURCE from the
# system settings: RETROBOX_KEYBOARD_FILE (/etc/default/keyboard), else
# localectl (Arch and anything with systemd's X11 keymap), else plain "us".
detect_keyboard() {
  local status
  KB_SOURCE=""
  XKB_MODEL="" XKB_LAYOUT="" XKB_VARIANT="" XKB_OPTIONS=""

  if [[ -r "${RETROBOX_KEYBOARD_FILE}" ]]; then
    XKB_LAYOUT="$(kb_file_value "${RETROBOX_KEYBOARD_FILE}" XKBLAYOUT)"
    if [[ -n "${XKB_LAYOUT}" ]]; then
      XKB_MODEL="$(kb_file_value "${RETROBOX_KEYBOARD_FILE}" XKBMODEL)"
      XKB_VARIANT="$(kb_file_value "${RETROBOX_KEYBOARD_FILE}" XKBVARIANT)"
      XKB_OPTIONS="$(kb_file_value "${RETROBOX_KEYBOARD_FILE}" XKBOPTIONS)"
      KB_SOURCE="${RETROBOX_KEYBOARD_FILE}"
      return 0
    fi
  fi

  # (localectl fails without a running systemd: that is no error here)
  if status="$(localectl status 2>/dev/null)"; then
    XKB_LAYOUT="$(kb_localectl_value "${status}" Layout)"
    if [[ -n "${XKB_LAYOUT}" ]]; then
      XKB_MODEL="$(kb_localectl_value "${status}" Model)"
      XKB_VARIANT="$(kb_localectl_value "${status}" Variant)"
      XKB_OPTIONS="$(kb_localectl_value "${status}" Options)"
      KB_SOURCE="localectl"
      return 0
    fi
  fi

  XKB_LAYOUT="us"
  # shellcheck disable=SC2034  # read by the callers
  KB_SOURCE="default (no system keyboard found)"
}

# Exports XKB_DEFAULT_* for labwc (libxkbcommon reads them) from the system
# keyboard; whatever the environment had before is replaced.
export_keyboard_env() {
  detect_keyboard
  export XKB_DEFAULT_LAYOUT="${XKB_LAYOUT}"
  if [[ -n "${XKB_MODEL}" ]]; then export XKB_DEFAULT_MODEL="${XKB_MODEL}"; else unset XKB_DEFAULT_MODEL; fi
  if [[ -n "${XKB_VARIANT}" ]]; then export XKB_DEFAULT_VARIANT="${XKB_VARIANT}"; else unset XKB_DEFAULT_VARIANT; fi
  if [[ -n "${XKB_OPTIONS}" ]]; then export XKB_DEFAULT_OPTIONS="${XKB_OPTIONS}"; else unset XKB_DEFAULT_OPTIONS; fi
}
