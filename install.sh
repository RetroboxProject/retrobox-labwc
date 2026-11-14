#!/usr/bin/env bash
# retrobox-labwc: installer of the labwc gaming session for minimal systems
# (Debian netinstall, Arch, ...). It installs no packages: it CHECKS that
# what the session needs is there and sets up the rest.
#
# The session runs as a systemd service (retrobox-labwc.service) that owns
# the gaming TTY and logs your user in on it, so there is no autologin and
# no login hook. You manage it like any service:
#   systemctl stop retrobox-labwc     bare system: the TTY gets its login prompt
#   systemctl start retrobox-labwc    the gaming session again
#   systemctl restart retrobox-labwc  start it over (e.g. after a keyboard change)
#
# It checks:
#   * labwc, pipewire-pulse and a terminal (foot or alacritty) are installed
#     (also dbus-run-session, which the session needs; the rest is advice)
#
# The service and a polkit rule are the only things that need root (it asks
# for your password through sudo): /etc/systemd/system/retrobox-labwc.service,
# enabled at boot, and /etc/polkit-1/rules.d/50-retrobox-labwc.rules, which
# lets your user start and stop that service, power off and reboot from any
# session (so ssh and the systemctl reboot/poweroff sent by EmulationStation
# need no password). Pass --no-system to leave /etc alone, or --no-polkit to
# skip just the rule.
#
# It sets up, in your home only:
#   * ~/.local/share/retrobox-labwc    this tree (so the checkout can go)
#   * ~/.config/retrobox-labwc         labwc's config for the session
#   * ~/.config/retrobox/retrobox.ini.d/50-labwc.ini   the gaming TTY
#
# The keyboard is always the system's (/etc/default/keyboard on Debian,
# localectl elsewhere), read every time the session starts. After changing
# it (Debian: sudo dpkg-reconfigure keyboard-configuration) press
# Win+Shift+R in the session, or restart the service.
#
# Once installed, the TTY cannot be changed: uninstall first, then install.
#
# Usage: ./install.sh [--tty N] [--on-quit poweroff|shell] [--no-system] [--no-polkit] [--force]
#        ./install.sh --check [--tty N]
#        ./install.sh --uninstall
#   --tty N       gaming TTY (1-12); required the first time
#   --on-quit X   what happens when Retrobox quits normally (exit status 0):
#                 poweroff (the default the first time) or shell (the service
#                 ends and the TTY gets its login prompt); a re-run keeps the
#                 current choice unless given
#   --check       only run the checks, change nothing
#   --no-system   never touch /etc (no sudo): a missing service is an error
#   --no-polkit   do not write the polkit rule
#   --force       install even if a check fails
#   --uninstall   remove everything this script set up, /etc files included
#   -h, --help
set -euo pipefail

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SELF
SELF_DIR="$(dirname -- "${SELF}")"
readonly SELF_DIR
# shellcheck source=libexec/retrobox-labwc-common.sh
source "${SELF_DIR}/libexec/retrobox-labwc-common.sh"

readonly GENERATED_MARK="by retrobox-labwc"
readonly BLOCK_BEGIN="# >>> retrobox-labwc (managed by its install.sh; removed by --uninstall) >>>"
readonly BLOCK_END="# <<< retrobox-labwc <<<"
readonly DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/retrobox-labwc"
readonly CONFIG_DIR="${RETROBOX_LABWC_CONFIG_DIR}"
readonly RETROBOX_CONFIG_DIR="${RETROBOX_CONFIGDIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/retrobox}"
readonly TTY_DROPIN="${RETROBOX_CONFIG_DIR}/retrobox.ini.d/50-labwc.ini"
readonly MANIFEST="${DATA_DIR}/.install-manifest"
readonly BIN_DIR="${HOME}/.local/bin"
readonly SESSION_LINK="${BIN_DIR}/retrobox-labwc-session"
readonly POLKIT_DIR="${RETROBOX_POLKIT_DIR:-/etc/polkit-1/rules.d}"
readonly SYSTEMD_DIR="${RETROBOX_SYSTEMD_DIR:-/etc/systemd/system}"
readonly OS_RELEASE="${RETROBOX_OS_RELEASE:-/etc/os-release}"
# the files bash reads for a login shell, in the order it tries them
readonly PROFILES=(".bash_profile" ".bash_login" ".profile")
# what is copied into DATA_DIR
readonly TREE=(install.sh bin libexec share)

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then B=$'\033[1m'; R=$'\033[0m'; else B=""; R=""; fi
info() { echo "${B}[INFO]${R} $*"; }
ok() { echo "${B}[ OK ]${R} $*"; }
warn() { echo "${B}[WARN]${R} $*" >&2; }
bad() { echo "${B}[MISS]${R} $*" >&2; }
die() {
  echo "${B}[ERR ]${R} $*" >&2
  exit 1
}

usage() { sed -n '2,/^set -euo/p' "${SELF}" | sed '$d; s/^# \{0,1\}//'; }

have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------- checks
# Which package manager's names to suggest: apt, pacman, dnf or "".
detect_pm() {
  local ids=""
  # shellcheck source=/dev/null
  [[ -r "${OS_RELEASE}" ]] && ids="$(. "${OS_RELEASE}" && echo " ${ID:-} ${ID_LIKE:-} ")"
  case "${ids}" in
  *" debian "* | *" ubuntu "*) echo apt ;;
  *" arch "*) echo pacman ;;
  *" fedora "* | *" rhel "*) echo dnf ;;
  *) echo "" ;;
  esac
}

# pkg_name PM KEY: the package that provides KEY on that distribution.
pkg_name() {
  case "$1:$2" in
  *:labwc) echo labwc ;;
  *:terminal) echo foot ;;
  *:wlr-randr) echo wlr-randr ;;
  *:wireplumber) echo wireplumber ;;
  apt:polkit) echo polkitd ;;
  pacman:polkit) echo polkit ;;
  apt:pipewire-pulse | pacman:pipewire-pulse) echo pipewire-pulse ;;
  dnf:pipewire-pulse) echo pipewire-pulseaudio ;;
  apt:dbus) echo dbus-bin ;;
  pacman:dbus) echo dbus ;;
  dnf:dbus) echo dbus-daemon ;;
  apt:xwayland) echo xwayland ;;
  pacman:xwayland) echo xorg-xwayland ;;
  dnf:xwayland) echo xorg-x11-server-Xwayland ;;
  *) echo "$2" ;;
  esac
}

# True if systemd's user units include pipewire-pulse (Arch ships the
# pipewire-pulse command inside the pipewire package, so the command alone
# proves nothing there).
pipewire_pulse_unit() {
  local dir
  local -a dirs
  IFS=: read -r -a dirs <<<"${RETROBOX_USER_UNIT_DIRS:-/usr/lib/systemd/user:/lib/systemd/user:/etc/systemd/user}"
  for dir in "${dirs[@]}"; do
    [[ -e "${dir}/pipewire-pulse.service" || -e "${dir}/pipewire-pulse.socket" ]] && return 0
  done
  return 1
}

MISSING_REQUIRED=()
MISSING_OPTIONAL=()
FAILED=0

# check_required KEY LABEL CMD...: ok if any of the commands exists.
check_required() {
  local key="$1" label="$2" cmd
  shift 2
  for cmd in "$@"; do
    if have "${cmd}"; then
      ok "${label}: $(command -v "${cmd}")"
      return 0
    fi
  done
  bad "${label} is not installed"
  MISSING_REQUIRED+=("${key}")
  FAILED=1
}

# check_optional KEY LABEL WHAT CMD: warns, never fails.
check_optional() {
  if have "$4"; then
    ok "$2: $(command -v "$4")"
  else
    warn "$2 not found (needed for $3)"
    MISSING_OPTIONAL+=("$1")
  fi
}

check_dependencies() {
  local tty="$1"
  check_required labwc labwc labwc
  if have pipewire-pulse && { ! have systemctl || pipewire_pulse_unit; }; then
    ok "pipewire-pulse: $(command -v pipewire-pulse)"
  else
    bad "pipewire-pulse is not installed"
    MISSING_REQUIRED+=(pipewire-pulse)
    FAILED=1
  fi
  check_required terminal "terminal (foot or alacritty)" foot alacritty
  check_required dbus "dbus-run-session" dbus-run-session
  ((tty == 1)) || check_required kbd "chvt (to boot on tty${tty})" chvt
  check_optional wlr-randr wlr-randr "Win+P, the display switch" wlr-randr
  check_optional wireplumber wpctl "the volume keys" wpctl
  check_optional xwayland Xwayland "emulators that need X11" Xwayland
  check_optional polkit pkcheck "power off and reboot from the session" pkcheck
  check_optional wlrctl wlrctl "mouse-hide and mouse-show, which move the pointer" wlrctl
  if find_retrobox_root >/dev/null; then
    ok "retrobox-core: $(find_retrobox_root)"
  else
    warn "retrobox-core not found (no retrobox command): the session cannot start without it"
  fi

  print_install_hint
}

print_install_hint() {
  local pm key cmd
  local -a pkgs=() rec=()
  ((${#MISSING_REQUIRED[@]} + ${#MISSING_OPTIONAL[@]} > 0)) || return 0
  pm="$(detect_pm)"
  for key in "${MISSING_REQUIRED[@]}"; do pkgs+=("$(pkg_name "${pm}" "${key}")"); done
  for key in "${MISSING_OPTIONAL[@]}"; do rec+=("$(pkg_name "${pm}" "${key}")"); done
  case "${pm}" in
  apt) cmd="sudo apt install" ;;
  pacman) cmd="sudo pacman -S --needed" ;;
  dnf) cmd="sudo dnf install" ;;
  *) cmd="install with your package manager:" ;;
  esac
  ((${#pkgs[@]} == 0)) || info "Required: ${cmd} ${pkgs[*]}"
  ((${#rec[@]} == 0)) || info "Recommended: ${cmd} ${rec[*]}"
}

UNIT_NAME="retrobox-labwc.service"
readonly UNIT_NAME

unit_path() {
  printf '%s/%s\n' "${SYSTEMD_DIR}" "${UNIT_NAME}"
}

# unit_content TTY: the service. It takes TTY over from its getty (Conflicts=),
# logs USER_NAME in through PAM (a real logind session on the seat, which is
# what labwc needs) and runs the session from a login shell, so your PATH is
# the one of your profile. When it ends, however it ends, the getty comes back.
unit_content() {
  local tty="$1" chvt systemctl_bin
  chvt="$(PATH="${PATH}:/usr/sbin:/sbin" command -v chvt || true)"
  chvt="${chvt:-/usr/bin/chvt}"
  systemctl_bin="$(command -v systemctl || true)"
  systemctl_bin="${systemctl_bin:-/usr/bin/systemctl}"
  cat <<UNIT
# Written ${GENERATED_MARK}: the labwc gaming session of ${USER_NAME} on tty${tty}.
# systemctl stop ${UNIT_NAME} gives tty${tty} its login prompt back.
[Unit]
Description=Retrobox labwc gaming session (tty${tty})
After=systemd-user-sessions.service plymouth-quit-wait.service systemd-logind.service getty@tty${tty}.service
Conflicts=getty@tty${tty}.service

[Service]
Type=simple
User=${USER_NAME}
PAMName=login
TTYPath=/dev/tty${tty}
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty${tty}
UtmpMode=user
Environment=RETROBOX_LABWC_TTY=${tty}
ExecStartPre=+-${chvt} ${tty}
ExecStart=/bin/bash -lc 'exec ${DATA_DIR}/bin/retrobox-labwc-session'
ExecStopPost=+-${systemctl_bin} --no-block start getty@tty${tty}.service
Restart=no
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
UNIT
}

# What the system part needs; set by check_service.
NEED_SERVICE=0

check_service() {
  local tty="$1" file
  NEED_SERVICE=0
  file="$(unit_path)"
  if [[ ! -f "${file}" ]]; then
    bad "the service ${UNIT_NAME} is not installed"
    NEED_SERVICE=1
  elif [[ "$(cat -- "${file}")" != "$(unit_content "${tty}")" ]]; then
    bad "the service ${UNIT_NAME} is not up to date"
    NEED_SERVICE=1
  else
    ok "the service ${UNIT_NAME} is in place (tty${tty})"
  fi
}

print_service_hint() {
  local tty="$1" file
  file="$(unit_path)"
  info "install.sh sets this up for you (with sudo); by hand it is:"
  echo "  sudo tee ${file} >/dev/null <<'UNIT'"
  unit_content "${tty}"
  echo "UNIT"
  echo "  sudo systemctl daemon-reload"
  echo "  sudo systemctl enable ${UNIT_NAME}"
}

# Writes the service and enables it at boot. Records what it did in
# SYSTEM_NOTES for the manifest (so --uninstall can undo exactly it).
SYSTEM_NOTES=""
PREV_NOTES=""
install_service() {
  local tty="$1" file tmp
  file="$(unit_path)"
  have sudo || die "sudo is needed for the service (or do it yourself and use --no-system)"
  if ((NEED_SERVICE == 1)); then
    info "Writing the service (sudo): ${file}"
    tmp="$(mktemp)"
    unit_content "${tty}" >"${tmp}"
    sudo install -d -m 0755 -- "${SYSTEMD_DIR}" || die "sudo failed"
    sudo install -m 0644 -- "${tmp}" "${file}" || die "sudo failed"
    rm -f -- "${tmp}"
    sudo systemctl daemon-reload
  fi
  if ! systemctl is-enabled --quiet "${UNIT_NAME}" 2>/dev/null; then
    sudo systemctl enable "${UNIT_NAME}" >/dev/null 2>&1 || die "could not enable ${UNIT_NAME}"
  fi
  SYSTEM_NOTES+="system_unit=${file}"$'\n'
}

# manifest_get KEY: the value recorded in the manifest, if any.
manifest_get() {
  [[ -f "${MANIFEST}" ]] || return 0
  sed -n "s/^$1=//p" "${MANIFEST}" | head -n1
}

# What an earlier version of this installer left: an autologin drop-in on the
# getty (the session started from a login hook). The service replaces it.
remove_old_dropin() {
  local dropin enabled tty
  dropin="$(manifest_get system_dropin)"
  enabled="$(manifest_get getty_enabled)"
  tty="$(installed_tty || true)"
  [[ -n "${dropin}" ]] || return 0
  if ((SYSTEM == 0)) || ! have sudo; then
    warn "Left in the system (remove as root): ${dropin}"
    [[ -z "${enabled}" ]] || warn "  and: systemctl disable getty@tty${tty}.service"
    return 0
  fi
  info "Removing the autologin drop-in of the previous install (sudo): ${dropin}"
  grep -qsF "${GENERATED_MARK}" "${dropin}" && sudo rm -f -- "${dropin}"
  sudo rmdir --ignore-fail-on-non-empty -- "$(dirname -- "${dropin}")" 2>/dev/null || true
  [[ -z "${enabled}" ]] || sudo systemctl disable "getty@tty${tty}.service" >/dev/null 2>&1 || true
  sudo systemctl daemon-reload
}

# merge_notes: SYSTEM_NOTES plus, for each key it lacks, the line an earlier
# run recorded (a re-run that finds everything in place adds nothing).
merge_notes() {
  local key line
  local -a keys=(system_unit polkit_rule)
  # an old autologin drop-in that could not be removed (--no-system) stays on record
  ((SYSTEM == 1)) || keys+=(system_dropin getty_enabled)
  for key in "${keys[@]}"; do
    grep -q "^${key}=" <<<"${SYSTEM_NOTES}" && continue
    line="$(grep "^${key}=" <<<"${PREV_NOTES}" || true)"
    [[ -z "${line}" ]] || SYSTEM_NOTES+="${line}"$'\n'
  done
}

polkit_rule_path() {
  printf '%s/50-retrobox-labwc.rules\n' "${POLKIT_DIR}"
}

polkit_rule_content() {
  cat <<RULE
// Written ${GENERATED_MARK}: ${USER_NAME} may power off and reboot from any
// session (EmulationStation sends systemctl poweroff and reboot) and start,
// stop and restart ${UNIT_NAME} (ssh included).
polkit.addRule(function(action, subject) {
  if (subject.user != "${USER_NAME}") {
    return polkit.Result.NOT_HANDLED;
  }
  if (action.id.indexOf("org.freedesktop.login1.power-off") == 0 ||
      action.id.indexOf("org.freedesktop.login1.reboot") == 0) {
    return polkit.Result.YES;
  }
  if (action.id == "org.freedesktop.systemd1.manage-units" &&
      action.lookup("unit") == "${UNIT_NAME}") {
    return polkit.Result.YES;
  }
  return polkit.Result.NOT_HANDLED;
});
RULE
}

# Lets the user power off, reboot and manage the service without a password.
install_polkit_rule() {
  local file tmp
  file="$(polkit_rule_path)"
  if ! have pkcheck; then
    warn "polkit is not installed: no rule written, power off and reboot may ask for a password."
    return 0
  fi
  if [[ -f "${file}" && "$(cat -- "${file}")" == "$(polkit_rule_content)" ]]; then
    ok "polkit rule already in place (${file})"
    return 0
  fi
  have sudo || die "sudo is needed for the polkit rule (or use --no-polkit)"
  info "Writing the polkit rule (sudo): ${file}"
  tmp="$(mktemp)"
  polkit_rule_content >"${tmp}"
  sudo install -d -m 0755 -- "${POLKIT_DIR}" || die "sudo failed"
  sudo install -m 0644 -- "${tmp}" "${file}" || die "sudo failed"
  rm -f -- "${tmp}"
  SYSTEM_NOTES+="polkit_rule=${file}"$'\n'
}

report_keyboard() {
  detect_keyboard
  info "Keyboard: ${XKB_LAYOUT}${XKB_VARIANT:+ ${XKB_VARIANT}} (from ${KB_SOURCE})"
  if [[ "${KB_SOURCE}" == default* ]]; then
    warn "no system keyboard found: Debian: sudo dpkg-reconfigure keyboard-configuration; others: localectl set-x11-keymap LAYOUT"
  fi
}

# --------------------------------------------------------------- install
# The gaming TTY that was installed, if the script ran before.
installed_tty() {
  [[ -f "${MANIFEST}" ]] || return 1
  sed -n 's/^tty=//p' "${MANIFEST}" | head -n1
}

# Escapes a string for the replacement side of a sed s||| expression.
sed_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//|/\\|}"
  printf '%s' "${value//&/\\&}"
}

# render TEMPLATE DESTINATION: fills in the @...@ placeholders of this
# install (and nothing else: rc.xml has wpctl's own @DEFAULT_AUDIO_SINK@).
render() {
  sed -e "s|@LABWC_DIR@|$(sed_escape "${DATA_DIR}")|g" \
    -e "s|@TERMINAL@|$(sed_escape "${TERMINAL}")|g" \
    -e "s|@SCREENSHOT_CMD@|$(sed_escape "${SCREENSHOT_CMD}")|g" \
    "$1" >"$2"
}

# Moves aside a file we are about to replace unless we generated it.
backup_foreign() {
  local file="$1" backup
  if [[ -f "${file}" && ! -L "${file}" ]] && ! grep -qF "${GENERATED_MARK}" "${file}"; then
    backup="${file}.bak-$(date +%Y%m%d%H%M%S)"
    mv -- "${file}" "${backup}"
    warn "Kept your own $(basename -- "${file}") as ${backup}"
  fi
}

copy_tree() {
  local item staging="${DATA_DIR}.new.$$"
  if [[ "${SELF_DIR}" == "$(realpath -m -- "${DATA_DIR}")" ]]; then
    return 0 # already running from the installed copy
  fi
  info "Copying the session files to ${DATA_DIR}..."
  rm -rf -- "${staging}"
  mkdir -p -- "${staging}"
  for item in "${TREE[@]}"; do cp -a -- "${SELF_DIR}/${item}" "${staging}/"; done
  # keep the manifest of a previous install (it is rewritten at the end)
  [[ -f "${MANIFEST}" ]] && cp -a -- "${MANIFEST}" "${staging}/"
  rm -rf -- "${DATA_DIR}.old.$$"
  [[ -e "${DATA_DIR}" ]] && mv -- "${DATA_DIR}" "${DATA_DIR}.old.$$"
  mv -- "${staging}" "${DATA_DIR}"
  rm -rf -- "${DATA_DIR}.old.$$"
}

write_labwc_config() {
  local root name
  info "Writing the labwc config to ${CONFIG_DIR}..."
  mkdir -p -- "${CONFIG_DIR}"

  TERMINAL="foot"
  have foot || TERMINAL="alacritty"
  if root="$(find_retrobox_root)" && [[ -x "${root}/bin/retrobox-screenshot" ]]; then
    SCREENSHOT_CMD="${root}/bin/retrobox-screenshot"
  else
    SCREENSHOT_CMD="retrobox-screenshot"
  fi

  for name in rc.xml autostart; do
    backup_foreign "${CONFIG_DIR}/${name}"
    rm -f -- "${CONFIG_DIR}/${name}"
    render "${DATA_DIR}/share/labwc/${name}.in" "${CONFIG_DIR}/${name}"
  done
  # no paths in it: linked, so updates apply right away
  backup_foreign "${CONFIG_DIR}/themerc-override"
  ln -sfn -- "${DATA_DIR}/share/labwc/themerc-override" "${CONFIG_DIR}/themerc-override"
}

# What a normal quit of retrobox does: the choice given, else the one already
# installed, else power off. The session reads it from this file.
write_on_quit() {
  local file="${CONFIG_DIR}/on_quit"
  [[ -n "${ON_QUIT}" ]] || ON_QUIT="$(cat -- "${file}" 2>/dev/null || true)"
  [[ -n "${ON_QUIT}" ]] || ON_QUIT="poweroff"
  info "When retrobox quits normally: ${ON_QUIT} (${file})"
  printf '%s\n' "${ON_QUIT}" >"${file}"
}

write_tty_setting() {
  info "Gaming TTY: ${TTY} (${TTY_DROPIN})"
  mkdir -p -- "$(dirname -- "${TTY_DROPIN}")"
  printf '# Written %s.\n[advanced]\nlabwc_tty = %s\n' "${GENERATED_MARK}" "${TTY}" >"${TTY_DROPIN}"
}

# Deletes our block from a profile (if it is there). Written back with cat so
# a symlinked profile (dotfile managers) stays a symlink.
remove_block() {
  local file="$1" tmp
  [[ -f "${file}" ]] && grep -qF "${BLOCK_BEGIN}" "${file}" || return 0
  tmp="$(mktemp)"
  awk -v begin="${BLOCK_BEGIN}" -v end="${BLOCK_END}" '
    $0 == begin { skip = 1; next }
    skip && $0 == end { skip = 0; next }
    !skip { print }
  ' "${file}" >"${tmp}"
  cat -- "${tmp}" >"${file}"
  rm -f -- "${tmp}"
}

# What the old packages' retrobox-labwc-setup left in the home directory:
# its hook would start a second session from the old install.
remove_legacy() {
  local hook="${HOME}/.bashrc.d/64_retrobox" name
  # the login hook of the previous version: the service replaces it
  for name in "${PROFILES[@]}"; do
    if grep -qsF "${BLOCK_BEGIN}" "${HOME}/${name}"; then
      info "Removing the old session hook from ~/${name} (the service replaces it)..."
      remove_block "${HOME}/${name}"
    fi
  done
  if grep -qsF "retrobox-labwc-setup" "${hook}"; then
    info "Removing the old session hook ${hook}..."
    rm -f -- "${hook}"
  fi
  if grep -qsF "retrobox-labwc-setup" "${HOME}/.config/labwc/rc.xml" 2>/dev/null; then
    warn "${HOME}/.config/labwc was written by the old retrobox-labwc-setup; it is not used any more (remove it by hand)."
  fi
  if [[ -e /usr/local/bin/go2tty || -e /etc/sudoers.d/retrobox-go2tty ]] ||
    compgen -G '/etc/sudoers.d/retrobox-labwc-*' >/dev/null; then
    warn "go2tty and its sudoers rules from the old install are still in the system and no longer needed (remove them as root)."
  fi
}

do_install() {
  local prev

  # what an earlier run did to the system, kept when this one has nothing to add
  PREV_NOTES="$(grep -E '^(system_unit|polkit_rule|system_dropin|getty_enabled)=' "${MANIFEST}" 2>/dev/null || true)"
  if prev="$(installed_tty)"; then
    if [[ -n "${TTY_ARG}" ]] && ((10#${TTY_ARG} != 10#${prev})); then
      die "already installed on tty${prev}: run ./install.sh --uninstall before using tty${TTY_ARG}"
    fi
    TTY="$((10#${prev}))"
    info "Already installed on tty${TTY}: updating."
  else
    [[ -n "${TTY_ARG}" ]] || die "which TTY? run it again with --tty N (e.g. --tty 1)"
    TTY="$((10#${TTY_ARG}))"
  fi

  info "Checking the system for tty${TTY}..."
  check_dependencies "${TTY}"
  check_service "${TTY}"
  report_keyboard
  if ((FAILED == 1)); then
    ((FORCE == 1)) || die "fix what is marked [MISS] above and run it again (or use --force)"
    warn "Installing anyway (--force)."
  fi
  if ((SYSTEM == 1)); then
    remove_old_dropin
    install_service "${TTY}"
  elif ((NEED_SERVICE == 1)); then
    if ((FORCE == 1)); then
      warn "The service is not set up (--no-system): the session will not start by itself."
    else
      print_service_hint "${TTY}"
      die "the service is not set up and --no-system was given (or use --force)"
    fi
  fi

  if ((SYSTEM == 1 && POLKIT == 1)); then install_polkit_rule; fi

  case "${DATA_DIR}${CONFIG_DIR}" in
  *[[:space:]\&\<\>\'\"\\]*) die "paths with spaces or quotes are not supported (${DATA_DIR}, ${CONFIG_DIR})" ;;
  *) ;;
  esac

  copy_tree
  write_labwc_config
  write_on_quit
  write_tty_setting
  remove_legacy

  mkdir -p -- "${BIN_DIR}"
  ln -sfn -- "${DATA_DIR}/bin/retrobox-labwc-session" "${SESSION_LINK}"
  [[ ":${PATH}:" == *":${BIN_DIR}:"* ]] || warn "${BIN_DIR} is not in your PATH (retrobox-labwc-session is linked there)."

  merge_notes
  printf 'tty=%s\nuser=%s\ndate=%s\n%s' "${TTY}" "${USER_NAME}" "$(date -Iseconds)" "${SYSTEM_NOTES}" >"${MANIFEST}"
  ok "Installed. The session starts at boot on tty${TTY}."
  info "Start it now: systemctl start ${UNIT_NAME}   (sudo if --no-polkit; stop gives the tty its login prompt)"
  if systemctl is-active --quiet "${UNIT_NAME}" 2>/dev/null; then
    info "The session is running with the files it started with: systemctl restart ${UNIT_NAME} to use the new ones."
  fi
  info "Remove it with: ${DATA_DIR}/install.sh --uninstall"
}

# ------------------------------------------------------------- uninstall
# Undoes what install_service and install_polkit_rule recorded in the manifest.
uninstall_system() {
  local unit rule dropin
  unit="$(manifest_get system_unit)"
  rule="$(manifest_get polkit_rule)"
  dropin="$(manifest_get system_dropin)"
  [[ -n "${unit}${rule}${dropin}" ]] || return 1
  if ((SYSTEM == 0)) || ! have sudo; then
    [[ -z "${unit}" ]] || warn "Left in the system (remove as root): ${unit} (and: systemctl disable ${UNIT_NAME})"
    [[ -z "${rule}" ]] || warn "Left in the system (remove as root): ${rule}"
    remove_old_dropin
    return 0
  fi
  if [[ -n "${rule}" ]]; then
    info "Removing ${rule} (sudo)..."
    grep -qsF "${GENERATED_MARK}" "${rule}" && sudo rm -f -- "${rule}"
  fi
  if [[ -n "${unit}" ]]; then
    info "Removing ${unit} (sudo)..."
    sudo systemctl disable "${UNIT_NAME}" >/dev/null 2>&1 || true
    grep -qsF "${GENERATED_MARK}" "${unit}" && sudo rm -f -- "${unit}"
    sudo systemctl daemon-reload
  fi
  remove_old_dropin
}

do_uninstall() {
  local name found=0
  cd /

  if uninstall_system; then found=1; fi

  for name in "${PROFILES[@]}"; do
    if grep -qsF "${BLOCK_BEGIN}" "${HOME}/${name}"; then
      info "Removing the session hook from ~/${name}..."
      remove_block "${HOME}/${name}"
      # a profile that only had our block is gone with it
      grep -qs '[^[:space:]]' "${HOME}/${name}" || rm -f -- "${HOME}/${name}"
      found=1
    fi
  done
  if [[ -d "${CONFIG_DIR}" ]]; then
    info "Removing ${CONFIG_DIR}..."
    rm -rf -- "${CONFIG_DIR}"
    found=1
  fi
  if grep -qsF "${GENERATED_MARK}" "${TTY_DROPIN}"; then
    info "Removing ${TTY_DROPIN}..."
    rm -f -- "${TTY_DROPIN}"
    rmdir --ignore-fail-on-non-empty -- "$(dirname -- "${TTY_DROPIN}")" 2>/dev/null || true
    found=1
  fi
  if [[ -L "${SESSION_LINK}" && "$(readlink -- "${SESSION_LINK}")" == "${DATA_DIR}/"* ]]; then
    rm -f -- "${SESSION_LINK}"
  fi
  if [[ -d "${DATA_DIR}" ]]; then
    info "Removing ${DATA_DIR}..."
    rm -rf -- "${DATA_DIR}"
    found=1
  fi

  if ((found == 0)); then
    info "Nothing to remove."
  else
    ok "Removed. If the session is still running: systemctl stop ${UNIT_NAME} (or reboot) gives the tty its login prompt back."
  fi
}

# ------------------------------------------------------------------ main
TTY_ARG=""
FORCE=0
ON_QUIT=""
SYSTEM=1
POLKIT=1
CHECK_ONLY=0
UNINSTALL=0
while (($# > 0)); do
  case "$1" in
  --tty)
    TTY_ARG="${2:?--tty needs a VT number}"
    shift 2
    ;;
  --on-quit)
    ON_QUIT="${2:?--on-quit needs poweroff or shell}"
    shift 2
    ;;
  --force)
    FORCE=1
    shift
    ;;
  --no-system)
    SYSTEM=0
    shift
    ;;
  --no-polkit)
    POLKIT=0
    shift
    ;;
  --check)
    CHECK_ONLY=1
    shift
    ;;
  --uninstall)
    UNINSTALL=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unknown option: $1 (see --help)" ;;
  esac
done

USER_NAME="$(id -un)"
readonly USER_NAME
((EUID != 0)) || die "run it as the user who plays, not as root: it needs no privileges"
[[ -z "${ON_QUIT}" || "${ON_QUIT}" == "poweroff" || "${ON_QUIT}" == "shell" ]] || die "--on-quit needs poweroff or shell"
[[ -z "${TTY_ARG}" ]] || is_valid_tty "${TTY_ARG}" || die "--tty needs a VT number between 1 and 12"

if ((UNINSTALL == 1)); then
  do_uninstall
  exit 0
fi

if ((CHECK_ONLY == 1)); then
  TTY="$(installed_tty || true)"
  if [[ -n "${TTY_ARG}" ]]; then TTY="$((10#${TTY_ARG}))"; fi
  [[ -n "${TTY}" ]] || die "which TTY? use --check --tty N"
  check_dependencies "${TTY}"
  check_service "${TTY}"
  report_keyboard
  if ((NEED_SERVICE == 1)); then
    FAILED=1
    print_service_hint "${TTY}"
  fi
  exit "${FAILED}"
fi

do_install
