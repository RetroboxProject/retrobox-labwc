#!/usr/bin/env bash
# Shared constants and helpers for the labwc gaming-session scripts.
# This file is meant to be sourced, never executed directly.
#
# No path is hardcoded:
#   * RETROBOX_LABWC_DIR is this component's own tree, derived from this
#     file's real location (<dir>/libexec/ -> <dir>).
#   * RETROBOX_ROOT is the retrobox-core install, found (in this order) from
#     $RETROBOX_ROOT, the parent of RETROBOX_LABWC_DIR (packages and
#     install.sh put this component in <core prefix>/labwc) and the
#     `retrobox` command on PATH. It may stay empty: only what really needs
#     retrobox-core (starting it) fails without it.
#
# retrobox.ini is read here with the same layering as retrobox-core
# (/etc/retrobox, then ~/.config/retrobox, each followed by its
# retrobox.ini.d/*.ini drop-ins; the last value wins), so neither Python nor
# retrobox-core is needed to know the gaming TTY. Under sudo, the invoking
# user's configuration is read, not root's.
#
# Safe to source more than once and from an interactive shell
# (~/.bashrc.d): no "readonly", no "exit", every helper returns.

if [[ -n "${RETROBOX_LABWC_COMMON_SOURCED:-}" ]]; then
  # shellcheck disable=SC2317  # "|| true" only matters if executed by mistake
  return 0 2>/dev/null || true
fi
RETROBOX_LABWC_COMMON_SOURCED=1

RETROBOX_LABWC_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." &>/dev/null && pwd -P)"
# (used by the scripts that source this file)
# shellcheck disable=SC2034
RETROBOX_GO2TTY="${RETROBOX_LABWC_DIR}/libexec/go2tty"

# The per-user runtime dir keeps the saved TTY private to its owner.
RETROBOX_TTYSAVE="${RETROBOX_TTYSAVE:-${XDG_RUNTIME_DIR:-/tmp}/retrobox-ttysave}"
# Where to return to when no origin TTY was saved (session started by
# hand on the gaming TTY instead of through retrobox-enter-tty).
RETROBOX_FALLBACK_TTY="${RETROBOX_FALLBACK_TTY:-1}"

# Prints the retrobox-core install root, or returns 1.
find_retrobox_root() {
  local candidate cmd

  for candidate in "${RETROBOX_ROOT:-}" "${RETROBOX_LABWC_DIR}/.."; do
    if [[ -n "${candidate}" && -x "${candidate}/bin/retrobox" ]]; then
      (cd -- "${candidate}" && pwd -P)
      return 0
    fi
  done

  cmd="$(command -v retrobox 2>/dev/null)" || return 1
  candidate="$(dirname -- "$(dirname -- "$(readlink -f -- "${cmd}")")")"
  [[ -x "${candidate}/bin/retrobox" ]] || return 1
  printf '%s\n' "${candidate}"
}

# Prints the home directory of the user the session belongs to: under sudo,
# the one who ran sudo.
session_home() {
  local home=""
  if ((EUID == 0)) && [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
  fi
  printf '%s\n' "${home:-${HOME}}"
}

# Prints the retrobox.ini files, lowest priority first.
retrobox_ini_files() {
  local sysconf="${RETROBOX_SYSCONFDIR:-/etc/retrobox}"
  local config layer dropin home

  home="$(session_home)"
  if ((EUID == 0)) && [[ -n "${SUDO_USER:-}" ]]; then
    # root's environment says nothing about the user's config directory
    config="${home}/.config/retrobox"
  else
    config="${RETROBOX_CONFIGDIR:-${XDG_CONFIG_HOME:-${home}/.config}/retrobox}"
  fi

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

# Prints the configured gaming TTY (retrobox.ini, [advanced] labwc_tty).
# Returns 1 with a message on stderr if it is missing or out of range;
# callers decide what to do (scripts exit, ~/.bashrc.d just gives up).
get_gaming_tty() {
  local tty

  tty="$(get_retrobox_setting advanced labwc_tty)" || {
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
