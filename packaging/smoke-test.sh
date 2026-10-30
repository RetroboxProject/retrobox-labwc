#!/usr/bin/env bash
# Smoke test for the retrobox-labwc .deb or .rpm. Meant for a throwaway
# container/VM: it installs the package system-wide and removes it afterwards.
#
#   sudo packaging/smoke-test.sh path/to/retrobox-labwc_X_all.deb
#   sudo packaging/smoke-test.sh path/to/retrobox-labwc-X-1.noarch.rpm
#
# A stand-in retrobox-core package is built first, so the test depends
# neither on a retrobox-core release nor on its own dependencies. Checks:
#   1. apt/dnf resolve every dependency from the distro's own repositories.
#   2. The tree is root-owned and not writable by others (go2tty runs as root).
#   3. retrobox-labwc-setup, as an unprivileged user, renders a labwc config
#      with this install's paths, the bashrc hook and the TTY drop-in, and the
#      scripts find retrobox-core and the gaming TTY.
#   4. With sudo, it writes a valid sudoers rule for go2tty and the autologin
#      drop-in, and -u removes them again.
#   5. Removing the package leaves nothing behind in /opt/retrobox/labwc.
set -euo pipefail

PKG_FILE="$(readlink -f "${1:?usage: $(basename "$0") path/to/package}")"
[[ "${EUID}" -eq 0 ]] || { echo "smoke-test: run as root" >&2; exit 1; }

fail() { echo "SMOKE TEST FAILED: $*" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- stand-in retrobox-core ---------------------------------------------------------
stub_tree() {  # stub_tree DESTDIR
    mkdir -p "$1/opt/retrobox/bin"
    printf '#!/bin/sh\necho "retrobox stub $*"\n' > "$1/opt/retrobox/bin/retrobox"
    printf '#!/bin/sh\nexit 0\n' > "$1/opt/retrobox/bin/retrobox-screenshot"
    chmod 755 "$1/opt/retrobox/bin/"*
    mkdir -p "$1/usr/bin"
    ln -s /opt/retrobox/bin/retrobox "$1/usr/bin/retrobox"
}

case "${PKG_FILE}" in
    *.deb)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        stub_tree "${WORK}/core"
        mkdir -p "${WORK}/core/DEBIAN"
        printf 'Package: retrobox-core\nVersion: 99\nArchitecture: all\nMaintainer: test <test@example.com>\nDescription: stand-in\n' \
            > "${WORK}/core/DEBIAN/control"
        dpkg-deb --root-owner-group --build "${WORK}/core" "${WORK}/core.deb" >/dev/null
        apt-get install -y -qq "${WORK}/core.deb" "${PKG_FILE}"
        remove_pkg() { apt-get purge -y -qq retrobox-labwc; }
        ;;
    *.rpm)
        dnf install -y -q rpm-build
        stub_tree "${WORK}/core"
        cat > "${WORK}/core.spec" <<SPEC
Name: retrobox-core
Version: 99
Release: 1
Summary: stand-in
License: none
BuildArch: noarch
%description
stand-in
%install
cp -a ${WORK}/core/. %{buildroot}/
%files
/opt/retrobox
/usr/bin/retrobox
SPEC
        rpmbuild -bb "${WORK}/core.spec" --define "_rpmdir ${WORK}/rpms" \
            --define "_topdir ${WORK}/rpmbuild" >/dev/null 2>&1 || fail "could not build the stand-in core"
        dnf install -y -q "${WORK}"/rpms/noarch/retrobox-core-*.rpm "${PKG_FILE}"
        remove_pkg() { dnf remove -y -q retrobox-labwc; }
        ;;
    *) fail "not a .deb or .rpm: ${PKG_FILE}" ;;
esac

LABWC=/opt/retrobox/labwc

echo "--- 1. commands and syntax"
for cmd in retrobox-labwc-setup retrobox-enter-tty retrobox-exit-tty retrobox-labwc-session; do
    [[ -x "/usr/bin/${cmd}" ]] || fail "/usr/bin/${cmd} is missing"
done
retrobox-labwc-setup --help | head -3
for f in "${LABWC}"/bin/* "${LABWC}"/libexec/*; do
    bash -n "${f}" || fail "syntax error in ${f}"
done

echo "--- 2. ownership"
[[ "$(stat -c '%U' "${LABWC}/libexec/go2tty")" == "root" ]] || fail "go2tty is not owned by root"
[[ -z "$(find "${LABWC}" -perm /022)" ]] || fail "files writable by group/others in ${LABWC}"

echo "--- 3. per-user setup (no sudo)"
id player >/dev/null 2>&1 || useradd -m player
as_player() { runuser -u player -- env -i HOME=/home/player PATH="${PATH}" "$@"; }
as_player retrobox-labwc-setup --tty 8 --no-system
cfg=/home/player/.config/labwc
for f in rc.xml autostart environment themerc-override; do
    [[ -e "${cfg}/${f}" ]] || fail "${cfg}/${f} was not written"
done
grep -q "${LABWC}/bin/retrobox-exit-tty -n" "${cfg}/rc.xml" || fail "rc.xml lacks the exit-tty path"
grep -q "/opt/retrobox/bin/retrobox-screenshot" "${cfg}/rc.xml" || fail "rc.xml lacks retrobox-core's screenshot command"
grep -q "@DEFAULT_AUDIO_SINK@" "${cfg}/rc.xml" || fail "rc.xml lost wpctl's own placeholder"
grep -qE '@(LABWC_DIR|SCREENSHOT_CMD|XKB_LAYOUT|XKB_VARIANT)@' "${cfg}/rc.xml" "${cfg}/autostart" "${cfg}/environment" \
    && fail "placeholders left in the rendered config"
grep -q "${LABWC}/libexec/retrobox-switch-display" "${cfg}/autostart" || fail "autostart lacks switch-display"
grep -qE '^XKB_DEFAULT_LAYOUT=[a-z]' "${cfg}/environment" || fail "no keyboard layout in environment"
bash -n /home/player/.bashrc.d/64_retrobox || fail "bashrc hook has a syntax error"
grep -q "labwc_tty = 8" /home/player/.config/retrobox/retrobox.ini.d/50-labwc.ini || fail "TTY drop-in missing"
# the shared helpers, as the session sees them
tty="$(as_player bash -c "source ${LABWC}/libexec/retrobox-labwc-common.sh && get_gaming_tty")"
[[ "${tty}" == "8" ]] || fail "get_gaming_tty gave '${tty}', expected 8"
root="$(as_player bash -c "source ${LABWC}/libexec/retrobox-labwc-common.sh && find_retrobox_root")"
[[ "${root}" == "/opt/retrobox" ]] || fail "find_retrobox_root gave '${root}'"
# a later layer (the user's own retrobox.ini) wins over /etc
mkdir -p /etc/retrobox && printf '[advanced]\nlabwc_tty = 3\n' > /etc/retrobox/retrobox.ini
tty="$(as_player bash -c "source ${LABWC}/libexec/retrobox-labwc-common.sh && get_gaming_tty")"
[[ "${tty}" == "8" ]] || fail "the user's drop-in should win over /etc, got '${tty}'"
# under sudo, the invoking user's configuration is read, not root's
tty="$(SUDO_USER=player bash -c "source ${LABWC}/libexec/retrobox-labwc-common.sh && get_gaming_tty")"
[[ "${tty}" == "8" ]] || fail "go2tty would not see the user's TTY (got '${tty}')"
rm -f /etc/retrobox/retrobox.ini

echo "--- 4. system parts (sudo)"
echo 'player ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/zz-smoke
chmod 440 /etc/sudoers.d/zz-smoke
as_player retrobox-labwc-setup --autologin
[[ -f /etc/sudoers.d/retrobox-labwc-player ]] || fail "no sudoers rule"
grep -q "NOPASSWD: ${LABWC}/libexec/go2tty" /etc/sudoers.d/retrobox-labwc-player || fail "wrong sudoers rule"
visudo -c >/dev/null || fail "sudoers no longer validates"
dropin=/etc/systemd/system/getty@tty8.service.d/retrobox-autologin.conf
grep -q -- "--autologin player " "${dropin}" || fail "no autologin drop-in"
as_player retrobox-labwc-setup -u
[[ ! -e /etc/sudoers.d/retrobox-labwc-player ]] || fail "-u left the sudoers rule"
[[ ! -e "${dropin}" ]] || fail "-u left the autologin drop-in"
[[ ! -e "${cfg}/rc.xml" && ! -e /home/player/.bashrc.d/64_retrobox ]] || fail "-u left user files"
rm -f /etc/sudoers.d/zz-smoke

echo "--- 5. removal"
as_player retrobox-labwc-setup --no-system >/dev/null
remove_pkg
[[ ! -e "${LABWC}" ]] || fail "${LABWC} is still there"
[[ ! -e /usr/bin/retrobox-labwc-setup ]] || fail "/usr/bin/retrobox-labwc-setup is still there"
[[ -x /opt/retrobox/bin/retrobox ]] || fail "removing retrobox-labwc touched retrobox-core"

echo "SMOKE TEST PASSED"
