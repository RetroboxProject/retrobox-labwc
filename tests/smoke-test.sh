#!/usr/bin/env bash
# Smoke test for install.sh and the session script, with stand-in commands
# (no labwc, no systemd, no root needed). Everything happens in a throwaway
# HOME.
#
#   tests/smoke-test.sh
# shellcheck disable=SC2015,SC2016  # "A && B || fail" is how the checks read
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fail() { echo "SMOKE TEST FAILED: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
expect_fail() { if "$@" >"${WORK}/out" 2>&1; then fail "should have failed: $*"; fi; }

export HOME="${WORK}/home"
mkdir -p "${HOME}"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME RETROBOX_CONFIGDIR
export XDG_RUNTIME_DIR="${WORK}/run"
mkdir -p "${XDG_RUNTIME_DIR}"
export RETROBOX_SYSCONFDIR="${WORK}/etc-retrobox"
export RETROBOX_KEYBOARD_FILE="${WORK}/keyboard"
export RETROBOX_OS_RELEASE="${WORK}/os-release"
printf 'ID=debian\n' >"${RETROBOX_OS_RELEASE}"
printf 'XKBMODEL="pc105"\nXKBLAYOUT="es"\nXKBVARIANT=""\nXKBOPTIONS="grp:alt_shift_toggle"\n' >"${RETROBOX_KEYBOARD_FILE}"

# --- stand-in commands -------------------------------------------------------------
STUBS="${WORK}/stubs"
mkdir -p "${STUBS}"
for cmd in labwc pipewire-pulse foot dbus-run-session wlr-randr wpctl Xwayland chvt retrobox; do
  printf '#!/bin/sh\nexit 0\n' >"${STUBS}/${cmd}"
done
mkdir -p "${WORK}/core/bin"
mv "${STUBS}/retrobox" "${WORK}/core/bin/retrobox"
printf '#!/bin/sh\nexit 0\n' >"${WORK}/core/bin/retrobox-screenshot"
# A fake systemd: units are the base ExecStart plus whatever drop-ins are in
# RETROBOX_SYSTEMD_DIR; "enabled" is a marker file. sudo just runs the command.
export RETROBOX_SYSTEMD_DIR="${WORK}/systemd"
export STUB_STATE="${WORK}/state"
export RETROBOX_POLKIT_DIR="${WORK}/polkit"
mkdir -p "${RETROBOX_SYSTEMD_DIR}" "${STUB_STATE}"
cat >"${STUBS}/systemctl" <<'SH'
#!/bin/sh
case "$1" in
  cat)
    tty="${2#getty@tty}"; tty="${tty%.service}"
    echo "ExecStart=-/sbin/agetty -o '-p -- \\u' --noclear %I \$TERM"
    cat "${RETROBOX_SYSTEMD_DIR}/getty@tty${tty}.service.d/"*.conf 2>/dev/null
    exit 0 ;;
  is-enabled) [ -e "${STUB_STATE}/enabled-$3" ] ;;
  enable) touch "${STUB_STATE}/enabled-$2" ;;
  disable) rm -f "${STUB_STATE}/enabled-$2" ;;
  daemon-reload) exit 0 ;;
  poweroff) touch "${STUB_STATE}/poweroff" ;;
  list-jobs) [ -e "${STUB_STATE}/reboot-pending" ] && echo "1 reboot.target start waiting" ; exit 0 ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/sh\nexec "$@"\n' >"${STUBS}/sudo"
chmod +x "${STUBS}"/* "${WORK}/core/bin/"*
export RETROBOX_ROOT="${WORK}/core"
BASE_PATH="${PATH}"
# systemd user units: pipewire-pulse's is only there once the package is
export RETROBOX_USER_UNIT_DIRS="${WORK}/units"
mkdir -p "${WORK}/units"

install_sh() { "${ROOT}/install.sh" "$@"; }

# --- 1. nothing installed: the check fails and says what to install -----------------
mkdir -p "${WORK}/bare"
for need in sed awk grep cat date mkdir rm cp mv ln tail head tr cut id readlink realpath dirname mktemp getent rmdir touch pgrep pkill sleep tty env; do
  ln -sf "$(PATH="${BASE_PATH}" command -v "${need}")" "${WORK}/bare/${need}"
done
PATH="${WORK}/bare" expect_fail "$(command -v bash)" "${ROOT}/install.sh" --check --tty 8; cat "${WORK}/out" >&2
grep -q 'labwc is not installed' "${WORK}/out" || fail "missing labwc not reported"
grep -q 'sudo apt install labwc pipewire-pulse foot dbus-bin' "${WORK}/out" || fail "install hint wrong: $(cat "${WORK}/out")"
PATH="${STUBS}:${BASE_PATH}"
pass "missing dependencies are reported with an apt hint"

# --- 1b. the pipewire-pulse command alone is not enough (Arch's pipewire package has it) ---
expect_fail install_sh --check --tty 8
grep -q 'pipewire-pulse is not installed' "${WORK}/out" || fail "pipewire-pulse without its unit accepted"
touch "${WORK}/units/pipewire-pulse.service"
pass "pipewire-pulse needs its systemd unit, not just the command"

# --- 2. the checks of the TTY: read-only, with the way to fix it -------------------------
expect_fail install_sh --check --tty 8
grep -q 'tty8 has no autologin' "${WORK}/out" || fail "missing autologin not reported"
grep -q 'does not boot on tty8' "${WORK}/out" || fail "missing boot not reported"
grep -q 'retrobox-labwc.conf' "${WORK}/out" && grep -q 'chvt 8' "${WORK}/out" || fail "no hint with the VT switch"
[[ -z "$(ls -A "${RETROBOX_SYSTEMD_DIR}")" ]] || fail "--check wrote to the system"
expect_fail install_sh --check --tty 1
grep -q 'chvt' "${WORK}/out" && fail "tty1 needs no VT switch"
mkdir -p "${RETROBOX_SYSTEMD_DIR}/getty@tty2.service.d"
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin somebody --noclear %%I $TERM\n' >"${RETROBOX_SYSTEMD_DIR}/getty@tty2.service.d/autologin.conf"
expect_fail install_sh --check --tty 2
grep -q "logs 'somebody' in" "${WORK}/out" || fail "other user's autologin not reported"
expect_fail install_sh --tty 2
grep -q "already logs 'somebody' in" "${WORK}/out" || fail "install over another user's autologin"
pass "the TTY checks are read-only; another user's autologin is never overridden"

# --- 3. install (sets the TTY up through sudo) --------------------------------------------
printf '# my profile\nexport FOO=1' >"${HOME}/.profile" # no trailing newline on purpose
expect_fail install_sh                                    # no --tty the first time
expect_fail install_sh --no-system --tty 8
grep -q 'not set up and --no-system' "${WORK}/out" || fail "--no-system did not refuse"
[[ ! -e "${HOME}/.local/share/retrobox-labwc" ]] || fail "--no-system left files behind"
install_sh --tty 8 >"${WORK}/out" 2>&1 || fail "install failed: $(cat "${WORK}/out")"
DROPIN="${RETROBOX_SYSTEMD_DIR}/getty@tty8.service.d/retrobox-labwc.conf"
grep -q -- "--autologin $(id -un)" "${DROPIN}" && grep -q 'ExecStartPre=-.*chvt 8' "${DROPIN}" || fail "drop-in wrong: $(cat "${DROPIN}")"
[[ -e "${STUB_STATE}/enabled-getty@tty8.service" ]] || fail "getty not enabled at boot"
install_sh --check --tty 8 >/dev/null 2>&1 || fail "check fails after the install"
DATA="${HOME}/.local/share/retrobox-labwc"
[[ -x "${DATA}/install.sh" && -x "${DATA}/bin/retrobox-labwc-session" ]] || fail "tree not copied"
grep -q 'labwc_tty = 8' "${HOME}/.config/retrobox/retrobox.ini.d/50-labwc.ini" || fail "tty not written"
grep -q "${DATA}/libexec/retrobox-switch-display" "${HOME}/.config/retrobox-labwc/autostart" || fail "autostart not rendered"
grep -q "<command>foot</command>" "${HOME}/.config/retrobox-labwc/rc.xml" || fail "terminal not rendered"
grep -q "${WORK}/core/bin/retrobox-screenshot" "${HOME}/.config/retrobox-labwc/rc.xml" || fail "screenshot not rendered"
grep -q '@DEFAULT_AUDIO_SINK@' "${HOME}/.config/retrobox-labwc/rc.xml" || fail "wpctl placeholder was clobbered"
! grep -q 'go2tty\|exit-tty' "${HOME}/.config/retrobox-labwc/rc.xml" || fail "leftovers in rc.xml"
[[ "$(grep -c 'retrobox-labwc (managed' "${HOME}/.profile")" == 1 ]] || fail "hook block missing"
grep -q '^export FOO=1$' "${HOME}/.profile" || fail "profile content damaged"
RULE="${RETROBOX_POLKIT_DIR}/50-retrobox-labwc.rules"
grep -q "subject.user == \"$(id -un)\"" "${RULE}" && grep -q 'login1.reboot' "${RULE}" && grep -q 'login1.power-off' "${RULE}" || fail "polkit rule wrong"
pass "install renders everything inside the home directory"

# --- 4. the TTY is locked once installed -----------------------------------------------
expect_fail install_sh --tty 2
grep -q 'already installed on tty8' "${WORK}/out" || fail "tty change not refused: $(cat "${WORK}/out")"
install_sh --tty 08 >/dev/null 2>&1 || fail "re-install on the same tty refused"
"${DATA}/install.sh" >/dev/null 2>&1 || fail "re-install without --tty from the installed copy failed"
[[ "$(grep -c 'retrobox-labwc (managed' "${HOME}/.profile")" == 1 ]] || fail "hook block duplicated"
pass "the TTY cannot change without uninstall; re-install is idempotent"

# --- 5. uninstall leaves the profile as it was -------------------------------------------
"${DATA}/install.sh" --uninstall >/dev/null 2>&1 || fail "uninstall failed"
[[ ! -e "${DATA}" && ! -e "${HOME}/.config/retrobox-labwc" && ! -e "${HOME}/.config/retrobox/retrobox.ini.d/50-labwc.ini" ]] || fail "files left"
[[ "$(cat "${HOME}/.profile")" == $'# my profile\nexport FOO=1' ]] || fail "profile not restored: $(cat "${HOME}/.profile")"
[[ ! -e "${DROPIN}" && ! -e "${STUB_STATE}/enabled-getty@tty8.service" ]] || fail "system part not undone"
[[ ! -e "${RULE}" ]] || fail "polkit rule not removed"
[[ -e "${RETROBOX_SYSTEMD_DIR}/getty@tty2.service.d/autologin.conf" ]] || fail "uninstall touched a drop-in that is not ours"
pass "uninstall restores the profile and undoes the system part"

# --- 5b. tty1 needs no VT switch; an autologin of yours is kept and only completed ---------
install_sh --tty 1 >/dev/null 2>&1 || fail "install on tty1 failed"
D1="${RETROBOX_SYSTEMD_DIR}/getty@tty1.service.d/retrobox-labwc.conf"
grep -q -- '--autologin' "${D1}" && ! grep -q chvt "${D1}" || fail "tty1 drop-in wrong: $(cat "${D1}")"
[[ ! -e "${STUB_STATE}/enabled-getty@tty1.service" ]] || fail "tty1 getty enabled needlessly"
"${HOME}/.local/share/retrobox-labwc/install.sh" --uninstall >/dev/null 2>&1
mkdir -p "${RETROBOX_SYSTEMD_DIR}/getty@tty3.service.d"
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin %s --noclear %%I $TERM\n' "$(id -un)" >"${RETROBOX_SYSTEMD_DIR}/getty@tty3.service.d/autologin.conf"
install_sh --tty 3 >/dev/null 2>&1 || fail "install on a tty with your own autologin failed"
D3="${RETROBOX_SYSTEMD_DIR}/getty@tty3.service.d/retrobox-labwc.conf"
grep -q 'chvt 3' "${D3}" && ! grep -q -- '--autologin' "${D3}" || fail "own autologin overridden: $(cat "${D3}")"
"${HOME}/.local/share/retrobox-labwc/install.sh" --uninstall >/dev/null 2>&1
[[ -e "${RETROBOX_SYSTEMD_DIR}/getty@tty3.service.d/autologin.conf" && ! -e "${D3}" ]] || fail "uninstall on tty3 wrong"
pass "tty1 gets no VT switch; your own autologin is kept and only completed"

# --- 6. a profile that does not exist yet is created, and removed again --------------------
rm -f "${HOME}/.profile"
printf 'echo rc\n' >"${HOME}/.bashrc"
install_sh --tty 8 >/dev/null 2>&1
grep -q '\. ~/.bashrc' "${HOME}/.bash_profile" || fail ".bash_profile does not read .bashrc"
"${HOME}/.local/share/retrobox-labwc/install.sh" --uninstall >/dev/null 2>&1
pass "a new ~/.bash_profile keeps reading ~/.bashrc"

# --- 7. keyboard: read from the system, at every start -----------------------------------
# shellcheck source=libexec/retrobox-labwc-common.sh
source "${ROOT}/libexec/retrobox-labwc-common.sh"
export_keyboard_env
[[ "${XKB_DEFAULT_LAYOUT}|${XKB_DEFAULT_MODEL}|${XKB_DEFAULT_OPTIONS}" == "es|pc105|grp:alt_shift_toggle" ]] || fail "keyboard env wrong"
[[ -z "${XKB_DEFAULT_VARIANT+x}" ]] || fail "empty variant exported"
printf 'XKBLAYOUT=de\nXKBVARIANT=nodeadkeys\n' >"${RETROBOX_KEYBOARD_FILE}"
export_keyboard_env
[[ "${XKB_DEFAULT_LAYOUT}|${XKB_DEFAULT_VARIANT}" == "de|nodeadkeys" && -z "${XKB_DEFAULT_MODEL+x}" ]] || fail "keyboard change not picked up"
pass "keyboard layout follows the system file"

# --- 8. the session: starts labwc + retrobox, passes the keyboard, restarts on request ------
printf 'XKBLAYOUT="es"\n' >"${RETROBOX_KEYBOARD_FILE}"
install_sh --tty 8 --on-quit shell >/dev/null 2>&1
[[ "$(cat "${HOME}/.config/retrobox-labwc/on_quit")" == "shell" ]] || fail "--on-quit shell not written"
RUNS="${WORK}/runs"
: >"${RUNS}"
# dbus-run-session -- CMD...
printf '#!/bin/sh\nshift\nexec "$@"\n' >"${STUBS}/dbus-run-session"
# labwc [-C DIR]: runs the autostart like labwc does, records its keyboard, lives until killed
cat >"${STUBS}/labwc" <<SH
#!/bin/sh
[ "\$1" = "-C" ] && dir="\$2"
echo "labwc layout=\$XKB_DEFAULT_LAYOUT dir=\$dir" >>"${RUNS}"
printf 'WAYLAND_DISPLAY=wayland-test\n' >"\${RETROBOX_LABWC_ENV_FILE}"
trap 'kill \$pid 2>/dev/null; exit 0' TERM
sleep 30 &
pid=\$!
wait
SH
# retrobox: first run waits (so the test can restart), later runs end by themselves
cat >"${WORK}/core/bin/retrobox" <<SH
#!/bin/sh
echo "retrobox display=\$WAYLAND_DISPLAY" >>"${RUNS}"
n=\$(grep -c '^retrobox' "${RUNS}")
if [ "\$n" -ge 2 ]; then exit 0; fi
exec sleep 30
SH
chmod +x "${STUBS}"/* "${WORK}/core/bin/retrobox"
export RETROBOX_LABWC_LOG="${WORK}/session.log"
"${HOME}/.local/bin/retrobox-labwc-session" -f &
SESSION=$!
for _ in $(seq 1 100); do grep -q '^retrobox' "${RUNS}" && break; sleep 0.1; done
grep -q 'labwc layout=es dir=.*/retrobox-labwc' "${RUNS}" || fail "labwc not started with the keyboard and config dir: $(cat "${RUNS}" "${RETROBOX_LABWC_LOG}")"
grep -q 'retrobox display=wayland-test' "${RUNS}" || fail "retrobox did not get labwc's environment"
printf 'XKBLAYOUT="fr"\n' >"${RETROBOX_KEYBOARD_FILE}"
"${HOME}/.local/bin/retrobox-labwc-session" --restart || fail "--restart failed"
for _ in $(seq 1 150); do kill -0 "${SESSION}" 2>/dev/null || break; sleep 0.1; done
wait "${SESSION}" || fail "session exited with an error"
[[ "$(grep -c '^labwc' "${RUNS}")" == 2 ]] || fail "session did not restart: $(cat "${RUNS}")"
grep -q 'labwc layout=fr' "${RUNS}" || fail "restart did not pick up the new keyboard: $(cat "${RUNS}")"
pgrep -u "$(id -u)" -f "sleep 30" >/dev/null && pkill -u "$(id -u)" -f "sleep 30" || true
pass "the session starts, restarts on request and re-reads the keyboard"

# --- 9. on_quit = poweroff: only a normal quit of retrobox powers off ---------------------
[[ ! -e "${STUB_STATE}/poweroff" ]] || fail "powered off without being asked"
printf '#!/bin/sh\nexit 0\n' >"${WORK}/core/bin/retrobox"
install_sh --tty 8 >/dev/null 2>&1 # a re-run keeps the choice
[[ "$(cat "${HOME}/.config/retrobox-labwc/on_quit")" == "shell" ]] || fail "re-run changed on_quit"
install_sh --tty 8 --on-quit poweroff >/dev/null 2>&1
[[ "$(cat "${HOME}/.config/retrobox-labwc/on_quit")" == "poweroff" ]] || fail "--on-quit poweroff not written"
"${HOME}/.local/bin/retrobox-labwc-session" -f || fail "session failed"
[[ -e "${STUB_STATE}/poweroff" ]] || fail "no poweroff after a normal quit"
rm -f "${STUB_STATE}/poweroff"
printf '#!/bin/sh\nexit 3\n' >"${WORK}/core/bin/retrobox"
"${HOME}/.local/bin/retrobox-labwc-session" -f || true
[[ ! -e "${STUB_STATE}/poweroff" ]] || fail "powered off after a crash"
pass "a normal quit powers off when on_quit says so, never after a failure"
printf '#!/bin/sh\nexit 0\n' >"${WORK}/core/bin/retrobox"
touch "${STUB_STATE}/reboot-pending"
"${HOME}/.local/bin/retrobox-labwc-session" -f || fail "session failed"
[[ ! -e "${STUB_STATE}/poweroff" ]] || fail "poweroff replaced a reboot already in progress"
rm -f "${STUB_STATE}/reboot-pending"
pass "a reboot requested by retrobox is not overridden by the poweroff"
expect_fail install_sh --on-quit reboot
"${HOME}/.local/share/retrobox-labwc/install.sh" --uninstall >/dev/null 2>&1
install_sh --tty 8 --no-polkit >/dev/null 2>&1 || fail "install --no-polkit failed"
[[ ! -e "${RULE}" ]] || fail "--no-polkit still wrote the rule"
pass "--no-polkit skips the rule"
rm -rf "${HOME}/.config/retrobox-labwc" "${HOME}/.local/share/retrobox-labwc"
install_sh --tty 8 >/dev/null 2>&1
[[ "$(cat "${HOME}/.config/retrobox-labwc/on_quit")" == "poweroff" ]] || fail "first install must default to poweroff"
pass "the first install powers off on quit by default"

# --- 10. the resolution is the kernel command line's video=, nothing else -----------------
RANDR_LOG="${WORK}/randr.log"
cat >"${STUBS}/wlr-randr" <<SH
#!/bin/sh
if [ \$# -eq 0 ]; then
  printf 'HDMI-A-2 "LG"\\n  Enabled: yes\\n'
else
  echo "\$*" >>"${RANDR_LOG}"
fi
SH
chmod +x "${STUBS}/wlr-randr"
DISPLAY_SH="${ROOT}/libexec/retrobox-switch-display"
randr_with() { # randr_with CMDLINE ARG: what wlr-randr was asked to do
  : >"${RANDR_LOG}"
  printf '%s\n' "$1" >"${WORK}/cmdline"
  RETROBOX_CMDLINE_FILE="${WORK}/cmdline" "${DISPLAY_SH}" "$2" >/dev/null 2>&1 || true
  cat "${RANDR_LOG}"
}
[[ "$(randr_with 'quiet video=HDMI-A-2:1280x720@60' mode)" == "--output HDMI-A-2 --mode 1280x720@60Hz" ]] || fail "video= not applied"
[[ -z "$(randr_with 'quiet video=HDMI-A-1:1280x720@60' mode)" ]] || fail "video= of another connector applied"
[[ -z "$(randr_with 'quiet video=efifb:off' mode)" ]] || fail "a non-mode video= applied"
[[ "$(randr_with 'video=HDMI-A-2:1280x720' mode)" == "--output HDMI-A-2 --mode 1280x720" ]] || fail "video= without refresh"
[[ "$(randr_with 'video=1280x720@50 video=HDMI-A-2:1024x768@60e' mode)" == "--output HDMI-A-2 --mode 1024x768@60Hz" ]] || fail "last video= must win, flags ignored"
[[ "$(randr_with 'video=1280x720-32@50' mode)" == "--output HDMI-A-2 --mode 1280x720@50Hz" ]] || fail "video= without connector"
[[ "$(randr_with 'quiet video=HDMI-A-2:1280x720@60' toggle)" == "--output HDMI-A-2 --on --mode 1280x720@60Hz --pos 0,0" ]] || fail "toggle ignores video="
[[ "$(randr_with 'quiet' toggle)" == "--output HDMI-A-2 --on --preferred --pos 0,0" ]] || fail "no video=: preferred mode expected"
grep -q 'retrobox-switch-display mode' "${HOME}/.config/retrobox-labwc/autostart" || fail "autostart does not apply the mode first"
pass "the resolution follows video= on the kernel command line, and only that"

# --- 11. mouse-hide / mouse-show ----------------------------------------------------------
WLRCTL_LOG="${WORK}/wlrctl.log"
printf '#!/bin/sh\necho "$*" >>"%s"\n' "${WLRCTL_LOG}" >"${STUBS}/wlrctl"
chmod +x "${STUBS}/wlrctl"
fake_randr() { # fake_randr MODE POSITION SCALE TRANSFORM: one enabled output, one disabled
  cat >"${STUBS}/wlr-randr" <<SH
#!/bin/sh
cat <<'OUT'
DP-1 "off"
  Enabled: no
  Modes:
    3840x2160 px, 60.000000 Hz (preferred, current)
  Position: 0,0
  Scale: 1.000000
  Transform: normal
HDMI-A-2 "LG"
  Enabled: yes
  Modes:
    1920x1080 px, 60.000000 Hz (preferred)
    $1 px, 60.000000 Hz (current)
  Position: $2
  Transform: $4
  Scale: $3
OUT
SH
  chmod +x "${STUBS}/wlr-randr"
}
: >"${WLRCTL_LOG}"
"${ROOT}/libexec/mouse-hide" || fail "mouse-hide failed"
[[ "$(cat "${WLRCTL_LOG}")" == "pointer move 32767 32767" ]] || fail "mouse-hide wrong: $(cat "${WLRCTL_LOG}")"
centre_of() { : >"${WLRCTL_LOG}"; fake_randr "$@"; "${ROOT}/libexec/mouse-show" || fail "mouse-show failed"; tail -n1 "${WLRCTL_LOG}"; }
[[ "$(centre_of 1280x720 0,0 1.000000 normal)" == "pointer move 640 360" ]] || fail "centre of 1280x720"
[[ "$(head -n1 "${WLRCTL_LOG}")" == "pointer move -32767 -32767" ]] || fail "mouse-show must start from the corner"
[[ "$(centre_of 1920x1080 0,0 2.000000 normal)" == "pointer move 480 270" ]] || fail "scale ignored"
[[ "$(centre_of 1920x1080 0,0 1.000000 90)" == "pointer move 540 960" ]] || fail "rotation ignored"
[[ "$(centre_of 1280x720 1920,0 1.000000 normal)" == "pointer move 2560 360" ]] || fail "position ignored"
PATH="${WORK}/bare" expect_fail "$(command -v bash)" "${ROOT}/libexec/mouse-hide"
grep -q 'wlrctl is not installed' "${WORK}/out" || fail "missing wlrctl not reported"
grep -q 'libexec/mouse-hide' "${HOME}/.config/retrobox-labwc/autostart" || fail "autostart does not run mouse-hide"
pass "mouse-hide parks the pointer in the corner, mouse-show centres it"

echo "All smoke tests passed."
