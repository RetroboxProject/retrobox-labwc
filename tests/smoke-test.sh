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

# --- 2. the check of the service: read-only, with the way to fix it ------------------------
UNIT="${RETROBOX_SYSTEMD_DIR}/retrobox-labwc.service"
expect_fail install_sh --check --tty 8
grep -q 'retrobox-labwc.service is not installed' "${WORK}/out" || fail "missing service not reported"
grep -q 'Conflicts=getty@tty8.service' "${WORK}/out" && grep -q 'PAMName=login' "${WORK}/out" || fail "no hint with the service"
[[ -z "$(ls -A "${RETROBOX_SYSTEMD_DIR}")" ]] || fail "--check wrote to the system"
expect_fail install_sh --no-system --tty 8
grep -q 'service is not set up and --no-system' "${WORK}/out" || fail "--no-system did not refuse"
pass "the service check is read-only and prints the way to set it up by hand"

# --- 3. install (writes the service through sudo) --------------------------------------------
printf '# my profile\nexport FOO=1' >"${HOME}/.profile" # no trailing newline on purpose
expect_fail install_sh # no --tty the first time
[[ ! -e "${HOME}/.local/share/retrobox-labwc" ]] || fail "--no-system left files behind"
install_sh --tty 8 >"${WORK}/out" 2>&1 || fail "install failed: $(cat "${WORK}/out")"
DATA="${HOME}/.local/share/retrobox-labwc"
grep -q "^User=$(id -un)\$" "${UNIT}" && grep -q '^TTYPath=/dev/tty8$' "${UNIT}" && grep -q '^Conflicts=getty@tty8.service$' "${UNIT}" || fail "unit wrong: $(cat "${UNIT}")"
grep -q '^Environment=RETROBOX_LABWC_TTY=8$' "${UNIT}" && grep -q "^ExecStart=/bin/bash -lc 'exec ${DATA}/bin/retrobox-labwc-session'\$" "${UNIT}" || fail "unit does not run the session: $(cat "${UNIT}")"
grep -q '^ExecStopPost=+-/bin/sh -c .*list-jobs.*retrobox-labwc.service +(start|restart).* --no-block start getty@tty8.service.$' "${UNIT}" && grep -q '^ExecStartPre=+-.*chvt 8$' "${UNIT}" || fail "unit does not give the tty back: $(cat "${UNIT}")"
[[ -e "${STUB_STATE}/enabled-retrobox-labwc.service" ]] || fail "service not enabled at boot"
install_sh --check --tty 8 >/dev/null 2>&1 || fail "check fails after the install"
[[ -x "${DATA}/install.sh" && -x "${DATA}/bin/retrobox-labwc-session" ]] || fail "tree not copied"
grep -q 'labwc_tty = 8' "${HOME}/.config/retrobox/retrobox.ini.d/50-labwc.ini" || fail "tty not written"
grep -q "${DATA}/libexec/retrobox-switch-display" "${HOME}/.config/retrobox-labwc/autostart" || fail "autostart not rendered"
grep -q "<command>foot</command>" "${HOME}/.config/retrobox-labwc/rc.xml" || fail "terminal not rendered"
grep -q "${WORK}/core/bin/retrobox-screenshot" "${HOME}/.config/retrobox-labwc/rc.xml" || fail "screenshot not rendered"
grep -q '@DEFAULT_AUDIO_SOURCE@' "${HOME}/.config/retrobox-labwc/rc.xml" || fail "wpctl placeholder was clobbered"
! grep -q 'go2tty\|exit-tty' "${HOME}/.config/retrobox-labwc/rc.xml" || fail "leftovers in rc.xml"
[[ "$(cat "${HOME}/.profile")" == $'# my profile\nexport FOO=1' ]] || fail "the profile was touched"
RULE="${RETROBOX_POLKIT_DIR}/50-retrobox-labwc.rules"
grep -q "subject.user != \"$(id -un)\"" "${RULE}" && grep -q 'login1.reboot' "${RULE}" && grep -q 'login1.power-off' "${RULE}" || fail "polkit rule wrong"
grep -q 'manage-units' "${RULE}" && grep -q 'action.lookup("unit") == "retrobox-labwc.service"' "${RULE}" || fail "polkit rule does not cover the service"
pass "install renders the service and the config; the profile stays untouched"

# --- 4. the TTY is locked once installed -----------------------------------------------
expect_fail install_sh --tty 2
grep -q 'already installed on tty8' "${WORK}/out" || fail "tty change not refused: $(cat "${WORK}/out")"
install_sh --tty 08 >/dev/null 2>&1 || fail "re-install on the same tty refused"
"${DATA}/install.sh" >/dev/null 2>&1 || fail "re-install without --tty from the installed copy failed"
grep -q 'system_unit=' "${DATA}/.install-manifest" && grep -q 'polkit_rule=' "${DATA}/.install-manifest" || fail "re-install lost the manifest notes"
pass "the TTY cannot change without uninstall; re-install is idempotent"

# --- 5. uninstall undoes the system part and leaves the profile as it was ------------------
"${DATA}/install.sh" --uninstall >/dev/null 2>&1 || fail "uninstall failed"
[[ ! -e "${DATA}" && ! -e "${HOME}/.config/retrobox-labwc" && ! -e "${HOME}/.config/retrobox/retrobox.ini.d/50-labwc.ini" ]] || fail "files left"
[[ "$(cat "${HOME}/.profile")" == $'# my profile\nexport FOO=1' ]] || fail "profile not restored: $(cat "${HOME}/.profile")"
[[ ! -e "${UNIT}" && ! -e "${STUB_STATE}/enabled-retrobox-labwc.service" ]] || fail "service not removed"
[[ ! -e "${RULE}" ]] || fail "polkit rule not removed"
pass "uninstall removes the service and the rule, and restores the profile"

# --- 5b. an install of the previous version (login hook + autologin drop-in) is migrated ---
OLD="${RETROBOX_SYSTEMD_DIR}/getty@tty8.service.d/retrobox-labwc.conf"
mkdir -p "$(dirname "${OLD}")" "${HOME}/.local/share/retrobox-labwc"
printf '# Written by retrobox-labwc: old\n[Service]\nExecStart=\n' >"${OLD}"
touch "${STUB_STATE}/enabled-getty@tty8.service"
printf 'tty=8\nuser=%s\nsystem_dropin=%s\ngetty_enabled=1\n' "$(id -un)" "${OLD}" >"${HOME}/.local/share/retrobox-labwc/.install-manifest"
printf '# my profile\n# >>> retrobox-labwc (managed by its install.sh; removed by --uninstall) >>>\n. hook\n# <<< retrobox-labwc <<<\n' >"${HOME}/.profile"
install_sh >/dev/null 2>&1 || fail "migration install failed"
[[ ! -e "${OLD}" && ! -e "${STUB_STATE}/enabled-getty@tty8.service" ]] || fail "old autologin drop-in left"
! grep -q 'retrobox-labwc' "${HOME}/.profile" && grep -q '^# my profile$' "${HOME}/.profile" || fail "old login hook left: $(cat "${HOME}/.profile")"
[[ -f "${UNIT}" ]] && ! grep -q 'system_dropin' "${HOME}/.local/share/retrobox-labwc/.install-manifest" || fail "migration did not switch to the service"
"${HOME}/.local/share/retrobox-labwc/install.sh" --uninstall >/dev/null 2>&1
pass "an install with the login hook and the autologin drop-in is migrated to the service"

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
printf '#!/bin/sh\necho private-bus >>"%s"\nshift\nexec "$@"\n' "${RUNS}" >"${STUBS}/dbus-run-session"
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

# --- 8b. a stop request (systemctl stop) closes labwc and retrobox promptly --------------
printf '#!/bin/sh\necho "retrobox display=\$WAYLAND_DISPLAY" >>"%s"\nexec sleep 30\n' "${RUNS}" >"${WORK}/core/bin/retrobox"
chmod +x "${WORK}/core/bin/retrobox"
: >"${RUNS}"
"${HOME}/.local/bin/retrobox-labwc-session" -f &
SESSION=$!
for _ in $(seq 1 100); do grep -q '^retrobox' "${RUNS}" && break; sleep 0.1; done
kill -TERM "${SESSION}"
for _ in $(seq 1 80); do kill -0 "${SESSION}" 2>/dev/null || break; sleep 0.1; done
! kill -0 "${SESSION}" 2>/dev/null || fail "the session did not stop on SIGTERM within 8s"
wait "${SESSION}" 2>/dev/null || true
! pgrep -u "$(id -u)" -x labwc >/dev/null || fail "labwc left behind after a stop request"
pass "SIGTERM stops the whole session promptly"

# --- 8c. the user's own bus is used when it exists; a private one is the fallback ------------
printf '#!/bin/sh\necho "bus=$DBUS_SESSION_BUS_ADDRESS user=${RETROBOX_LABWC_USER_BUS:-}" >>"%s"\nexit 0\n' "${RUNS}" >"${WORK}/core/bin/retrobox"
chmod +x "${WORK}/core/bin/retrobox"
: >"${RUNS}"
"${HOME}/.local/bin/retrobox-labwc-session" -f || fail "session without a user bus failed"
grep -q '^private-bus$' "${RUNS}" && grep -q 'user=$' "${RUNS}" || fail "no private bus without a user bus: $(cat "${RUNS}")"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${XDG_RUNTIME_DIR}/bus"
: >"${RUNS}"
"${HOME}/.local/bin/retrobox-labwc-session" -f || fail "session on the user bus failed"
grep -q "bus=unix:path=${XDG_RUNTIME_DIR}/bus user=1" "${RUNS}" && ! grep -q '^private-bus$' "${RUNS}" || fail "user bus not used: $(cat "${RUNS}")"
: >"${RUNS}"
RETROBOX_LABWC_PRIVATE_BUS=1 "${HOME}/.local/bin/retrobox-labwc-session" -f || fail "forced private bus failed"
grep -q '^private-bus$' "${RUNS}" || fail "RETROBOX_LABWC_PRIVATE_BUS ignored"
rm -f "${XDG_RUNTIME_DIR}/bus"
pass "the session uses the user bus when there is one, dbus-run-session otherwise"

# --- 8d. retrobox-audio-jack: analog duplex with headphones, HDMI without --------------------
# A stand-in pactl whose "list cards" comes from a file; set-card-profile is recorded.
printf '#!/bin/sh\ncase "$1" in\n  info) exit 0 ;;\n  list) cat "%s/cards.txt" ;;\n  set-card-profile) echo "$2 $3" >"%s/profile-set" ;;\nesac\n' "${STUB_STATE}" "${STUB_STATE}" >"${STUBS}/pactl"
chmod +x "${STUBS}/pactl"
# cards HEADPHONES(available|not available) ACTIVE HDMI(yes|no)
cards() {
  printf 'Card #46\n\tName: alsa_card.pci-0000_00_03.0\n\tProfiles:\n' >"${STUB_STATE}/cards.txt"
  {
    printf '\t\toutput:analog-stereo+input:analog-stereo: Duplex (sinks: 1, sources: 1, priority: 6565, available: yes)\n'
    printf '\t\toutput:hdmi-stereo: HDMI (sinks: 1, sources: 0, priority: 5900, available: %s)\n' "$3"
    printf '\t\toutput:hdmi-stereo+input:analog-stereo: HDMI y entrada (sinks: 1, sources: 1, priority: 5965, available: %s)\n' "$3"
    printf '\t\toff: Off (sinks: 0, sources: 0, priority: 0, available: yes)\n'
    printf '\tActive Profile: %s\n\tPorts:\n' "$2"
    printf '\t\tanalog-output-headphones: Auriculares (type: Headphones, priority: 9900, availability group: Legacy 3, %s)\n' "$1"
  } >>"${STUB_STATE}/cards.txt"
  rm -f "${STUB_STATE}/profile-set"
}
JACK="${ROOT}/libexec/retrobox-audio-jack"
ANALOG="output:analog-stereo+input:analog-stereo"
cards "not available" "${ANALOG}" yes
"${JACK}" --once 2>/dev/null
[[ "$(cat "${STUB_STATE}/profile-set")" == "alsa_card.pci-0000_00_03.0 output:hdmi-stereo+input:analog-stereo" ]] || fail "no HDMI profile without headphones: $(cat "${STUB_STATE}/profile-set" 2>&1)"
cards "available" "output:hdmi-stereo+input:analog-stereo" yes
"${JACK}" --once 2>/dev/null
[[ "$(cat "${STUB_STATE}/profile-set")" == "alsa_card.pci-0000_00_03.0 ${ANALOG}" ]] || fail "no analog profile with headphones"
cards "not available" "${ANALOG}" no
"${JACK}" --once 2>/dev/null
[[ ! -e "${STUB_STATE}/profile-set" ]] || fail "left analog without an HDMI profile available"
cards "available" "${ANALOG}" yes
"${JACK}" --once 2>/dev/null
[[ ! -e "${STUB_STATE}/profile-set" ]] || fail "changed a profile that was already right"
cards "not available" "${ANALOG}" yes
RETROBOX_AUDIO_HDMI_PROFILE=output:hdmi-stereo "${JACK}" --once 2>/dev/null
[[ "$(cat "${STUB_STATE}/profile-set")" == "alsa_card.pci-0000_00_03.0 output:hdmi-stereo" ]] || fail "RETROBOX_AUDIO_HDMI_PROFILE ignored"
grep -q 'retrobox-audio-jack' "${HOME}/.config/retrobox-labwc/autostart" || fail "audio jack script not in the autostart"
pass "the audio profile follows the headphone jack: analog duplex with them, HDMI without"

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
