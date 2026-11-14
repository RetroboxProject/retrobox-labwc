#!/usr/bin/env bash
# retrobox-labwc: user-level installer of the labwc gaming session for
# minimal systems (Debian netinstall, Arch, ...). It needs no root and
# installs no packages: it CHECKS that what the session needs is there and
# sets up everything else inside your home.
#
# It checks:
#   * labwc, pipewire-pulse and a terminal (foot or alacritty) are installed
#     (also dbus-run-session, which the session needs; the rest is advice)
#   * the gaming TTY logs your user in by itself (systemd getty autologin)
#     and the machine boots on it
#
# If the TTY does not log in by itself yet, or the machine does not boot on
# it, the installer sets that up (the only thing that needs root: it asks
# for your password through sudo): a drop-in
# /etc/systemd/system/getty@ttyN.service.d/retrobox-labwc.conf with the
# autologin and, for any TTY but 1, a VT switch to it at boot, and the getty
# enabled at boot. Pass --no-system to leave the system alone.
#
# It sets up, in your home only:
#   * ~/.local/share/retrobox-labwc    this tree (so the checkout can go)
#   * ~/.config/retrobox-labwc         labwc's config for the session
#   * ~/.config/retrobox/retrobox.ini.d/50-labwc.ini   the gaming TTY
#   * a block in your login profile (~/.bash_profile, ~/.bash_login or
#     ~/.profile) that starts the session on the gaming TTY
#
# The keyboard is always the system's (/etc/default/keyboard on Debian,
# localectl elsewhere), read every time the session starts. After changing
# it (Debian: sudo dpkg-reconfigure keyboard-configuration) press
# Win+Shift+R in the session, or log in again.
#
# Once installed, the TTY cannot be changed: uninstall first, then install.
#
# Usage: ./install.sh [--tty N] [--no-system] [--force]
#        ./install.sh --check [--tty N]
#        ./install.sh --uninstall
#   --tty N       gaming TTY (1-12); required the first time
#   --check       only run the checks, change nothing
#   --no-system   never touch /etc (no sudo): a missing autologin is an error
#   --force       install even if a check fails
#   --uninstall   remove everything this script set up, /etc drop-in included
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
  apt:pipewire-pulse | pacman:pipewire-pulse) echo pipewire-pulse ;;
  dnf:pipewire-pulse) echo pipewire-pulseaudio ;;
  apt:dbus) echo dbus-bin ;;
  pacman:dbus) echo dbus ;;
  dnf:dbus) echo dbus-daemon ;;
  apt:pactl | dnf:pactl) echo pulseaudio-utils ;;
  pacman:pactl) echo libpulse ;;
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
  check_optional pactl pactl "Win+O, the audio output switch" pactl
  check_optional xwayland Xwayland "emulators that need X11" Xwayland
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

# autologin_user TTY: prints the user getty@ttyTTY logs in by itself and
# returns 0, 1 if it asks for a login, 2 if this cannot be told (no systemd).
autologin_user() {
  local unit="getty@tty$1.service" exec_line user
  have systemctl || return 2
  # the merged unit, drop-ins included; the last ExecStart= is the one in force
  exec_line="$(systemctl cat "${unit}" 2>/dev/null | grep -E '^ExecStart=.' | tail -n1)" || return 2
  user="$(sed -n -E 's/.*[[:space:]](--autologin[=[:space:]]|-a[[:space:]])[[:space:]]*([^[:space:]]+).*/\2/p' <<<"${exec_line}")"
  [[ -n "${user}" ]] || return 1
  printf '%s\n' "${user}"
}

# True if the machine boots on TTY: tty1 always does; any other needs its
# getty enabled at boot and a VT switch to it.
boots_on_tty() {
  local tty="$1"
  ((tty == 1)) && return 0
  have systemctl || return 1
  systemctl is-enabled --quiet "getty@tty${tty}.service" 2>/dev/null || return 1
  systemctl cat "getty@tty${tty}.service" 2>/dev/null | grep -qE "^ExecStartPre=.*chvt[[:space:]]+${tty}([[:space:]]|\$)"
}

# What the system part needs; set by check_system_tty.
NEED_AUTOLOGIN=0
NEED_BOOT=0
OTHER_USER=""

check_system_tty() {
  local tty="$1" user rc=0
  NEED_AUTOLOGIN=0 NEED_BOOT=0 OTHER_USER=""

  user="$(autologin_user "${tty}")" || rc=$?
  case "${rc}" in
  0)
    if [[ "${user}" == "${USER_NAME}" ]]; then
      ok "tty${tty} logs ${USER_NAME} in by itself"
    else
      bad "tty${tty} logs '${user}' in by itself, not ${USER_NAME}"
      OTHER_USER="${user}"
    fi
    ;;
  1)
    bad "tty${tty} has no autologin"
    NEED_AUTOLOGIN=1
    ;;
  *)
    bad "cannot tell if tty${tty} has autologin: this needs a running systemd"
    FAILED=1
    return 0
    ;;
  esac

  if boots_on_tty "${tty}"; then
    ok "the machine boots on tty${tty}"
  else
    bad "the machine does not boot on tty${tty}"
    NEED_BOOT=1
  fi
}

# dropin_content TTY: the getty drop-in for what is needed (NEED_*).
dropin_content() {
  local tty="$1" agetty chvt
  agetty="$(PATH="${PATH}:/usr/sbin:/sbin" command -v agetty || true)"
  agetty="${agetty:-/sbin/agetty}"
  chvt="$(PATH="${PATH}:/usr/sbin:/sbin" command -v chvt || true)"
  chvt="${chvt:-/usr/bin/chvt}"
  printf '# Written %s: the labwc gaming session starts from this login.\n[Service]\n' "${GENERATED_MARK}"
  if ((NEED_AUTOLOGIN == 1)); then
    # shellcheck disable=SC2016  # $TERM is for agetty/systemd, not for us
    printf 'ExecStart=\nExecStart=-%s --autologin %s --noclear %%I $TERM\n' "${agetty}" "${USER_NAME}"
  fi
  if ((NEED_BOOT == 1)); then
    printf 'ExecStartPre=-%s %s\n' "${chvt}" "${tty}"
  fi
}

dropin_path() {
  printf '%s/getty@tty%s.service.d/retrobox-labwc.conf\n' "${SYSTEMD_DIR}" "$1"
}

print_system_hint() {
  local tty="$1" file
  file="$(dropin_path "${tty}")"
  info "install.sh sets this up for you (with sudo); by hand it is:"
  echo "  sudo mkdir -p $(dirname -- "${file}")"
  echo "  sudo tee ${file} >/dev/null <<'CONF'"
  dropin_content "${tty}"
  echo "CONF"
  ((tty == 1)) || echo "  sudo systemctl enable getty@tty${tty}.service"
  echo "  sudo systemctl daemon-reload"
}

# Makes TTY log in by itself and the machine boot on it. Records what it
# did in SYSTEM_NOTES for the manifest (so --uninstall can undo exactly it).
SYSTEM_NOTES=""
PREV_NOTES=""
install_system() {
  local tty="$1" file tmp
  file="$(dropin_path "${tty}")"
  have sudo || die "sudo is needed to set up tty${tty} (or do it yourself and use --no-system)"
  info "Setting up tty${tty} (sudo): ${file}"
  tmp="$(mktemp)"
  dropin_content "${tty}" >"${tmp}"
  sudo install -d -m 0755 -- "$(dirname -- "${file}")" || die "sudo failed"
  sudo install -m 0644 -- "${tmp}" "${file}" || die "sudo failed"
  rm -f -- "${tmp}"
  SYSTEM_NOTES="system_dropin=${file}"$'\n'
  if ((tty != 1)) && ! systemctl is-enabled --quiet "getty@tty${tty}.service" 2>/dev/null; then
    sudo systemctl enable "getty@tty${tty}.service" >/dev/null 2>&1 || die "could not enable getty@tty${tty}"
    SYSTEM_NOTES+="getty_enabled=1"$'\n'
  fi
  sudo systemctl daemon-reload
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

write_tty_setting() {
  info "Gaming TTY: ${TTY} (${TTY_DROPIN})"
  mkdir -p -- "$(dirname -- "${TTY_DROPIN}")"
  printf '# Written %s.\n[advanced]\nlabwc_tty = %s\n' "${GENERATED_MARK}" "${TTY}" >"${TTY_DROPIN}"
}

# The profile bash reads for a login shell: the first of PROFILES that
# exists, or a new ~/.bash_profile.
login_profile() {
  local name
  for name in "${PROFILES[@]}"; do
    [[ -f "${HOME}/${name}" ]] && {
      printf '%s\n' "${HOME}/${name}"
      return 0
    }
  done
  printf '%s\n' "${HOME}/.bash_profile"
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

install_login_hook() {
  local profile name
  profile="$(login_profile)"
  info "Adding the session hook to ${profile}..."
  for name in "${PROFILES[@]}"; do remove_block "${HOME}/${name}"; done
  if [[ ! -e "${profile}" ]]; then
    # bash skips ~/.bashrc in a login shell unless the profile reads it
    printf '%s\n' '[ -r ~/.bashrc ] && . ~/.bashrc' >"${profile}"
  fi
  [[ -s "${profile}" && -n "$(tail -c1 "${profile}")" ]] && echo >>"${profile}"
  {
    echo "${BLOCK_BEGIN}"
    echo "[ -n \"\${BASH_VERSION:-}\" ] && [ -r '${DATA_DIR}/share/login-hook.sh' ] && . '${DATA_DIR}/share/login-hook.sh'"
    echo "${BLOCK_END}"
  } >>"${profile}"
  if [[ "$(getent passwd "${USER_NAME}" | cut -d: -f7)" != */bash ]]; then
    warn "your login shell is not bash: the hook only works from bash (chsh -s /bin/bash)"
  fi
}

# What the old packages' retrobox-labwc-setup left in the home directory:
# its hook would start a second session from the old install.
remove_legacy() {
  local hook="${HOME}/.bashrc.d/64_retrobox"
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
  PREV_NOTES="$(grep -E '^(system_dropin|getty_enabled)=' "${MANIFEST}" 2>/dev/null || true)"
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
  check_system_tty "${TTY}"
  report_keyboard
  [[ -z "${OTHER_USER}" ]] || die "tty${TTY} already logs '${OTHER_USER}' in: pick another tty, or change it yourself"
  if ((FAILED == 1)); then
    ((FORCE == 1)) || die "fix what is marked [MISS] above and run it again (or use --force)"
    warn "Installing anyway (--force)."
  fi
  if ((NEED_AUTOLOGIN + NEED_BOOT > 0)); then
    if ((SYSTEM == 1)); then
      install_system "${TTY}"
    elif ((FORCE == 1)); then
      warn "tty${TTY} is not set up (--no-system): the session will not start by itself."
    else
      print_system_hint "${TTY}"
      die "tty${TTY} is not set up and --no-system was given (or use --force)"
    fi
  fi

  case "${DATA_DIR}${CONFIG_DIR}" in
  *[[:space:]\&\<\>\'\"\\]*) die "paths with spaces or quotes are not supported (${DATA_DIR}, ${CONFIG_DIR})" ;;
  *) ;;
  esac

  copy_tree
  write_labwc_config
  write_tty_setting
  install_login_hook
  remove_legacy

  mkdir -p -- "${BIN_DIR}"
  ln -sfn -- "${DATA_DIR}/bin/retrobox-labwc-session" "${SESSION_LINK}"
  [[ ":${PATH}:" == *":${BIN_DIR}:"* ]] || warn "${BIN_DIR} is not in your PATH (retrobox-labwc-session is linked there)."

  [[ -n "${SYSTEM_NOTES}" || -z "${PREV_NOTES}" ]] || SYSTEM_NOTES="${PREV_NOTES}"$'\n'
  printf 'tty=%s\nuser=%s\ndate=%s\n%s' "${TTY}" "${USER_NAME}" "$(date -Iseconds)" "${SYSTEM_NOTES}" >"${MANIFEST}"
  ok "Installed. Log in on tty${TTY} (or reboot) to start the session."
  info "Remove it with: ${DATA_DIR}/install.sh --uninstall"
}

# ------------------------------------------------------------- uninstall
# Undoes what install_system recorded in the manifest.
uninstall_system() {
  local dropin enabled tty
  dropin="$(sed -n 's/^system_dropin=//p' "${MANIFEST}" 2>/dev/null | head -n1)"
  enabled="$(sed -n 's/^getty_enabled=//p' "${MANIFEST}" 2>/dev/null | head -n1)"
  tty="$(installed_tty || true)"
  [[ -n "${dropin}" ]] || return 1
  if ((SYSTEM == 0)) || ! have sudo; then
    warn "Left in the system (remove as root): ${dropin}"
    [[ -z "${enabled}" ]] || warn "  and: systemctl disable getty@tty${tty}.service"
    return 0
  fi
  info "Removing ${dropin} (sudo)..."
  grep -qsF "${GENERATED_MARK}" "${dropin}" && sudo rm -f -- "${dropin}"
  sudo rmdir --ignore-fail-on-non-empty -- "$(dirname -- "${dropin}")" 2>/dev/null || true
  [[ -z "${enabled}" ]] || sudo systemctl disable "getty@tty${tty}.service" >/dev/null 2>&1 || true
  sudo systemctl daemon-reload
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
    ok "Removed. An autologin you set up yourself (not by this script) is left alone."
  fi
}

# ------------------------------------------------------------------ main
TTY_ARG=""
FORCE=0
SYSTEM=1
CHECK_ONLY=0
UNINSTALL=0
while (($# > 0)); do
  case "$1" in
  --tty)
    TTY_ARG="${2:?--tty needs a VT number}"
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
  check_system_tty "${TTY}"
  report_keyboard
  [[ -z "${OTHER_USER}" ]] || FAILED=1
  if ((NEED_AUTOLOGIN + NEED_BOOT > 0)); then
    FAILED=1
    print_system_hint "${TTY}"
  fi
  exit "${FAILED}"
fi

do_install
