# Spec for retrobox-labwc. The file tree is not built here: build-rpm.sh stages
# it with packaging/stage.sh (shared with the .deb and the install.sh tarball)
# and this spec only packs it. Placeholders (@...@) are filled by build-rpm.sh.
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
# the scripts' interpreters are plain /usr/bin/env bash: nothing to scan
%global __requires_exclude_from ^/opt/retrobox/labwc/.*$

Name:           retrobox-labwc
Version:        @VERSION@
Release:        1
Summary:        Retrobox labwc gaming session on its own TTY
License:        GPL-2.0-only
URL:            https://github.com/RetroboxProject/retrobox-labwc
BuildArch:      noarch
Requires:       retrobox-core
@REQUIRES@
@RECOMMENDS@

%description
Runs Retrobox inside a labwc Wayland session on a dedicated virtual terminal,
isolated from the desktop session (its own D-Bus session): retrobox-enter-tty
switches to it from the desktop, Win+D goes back, and the session closes
itself when Retrobox exits. Includes display and audio output switching
(Win+P, Win+O) and the labwc configuration it needs.

Installed under /opt/retrobox/labwc. Each user then runs retrobox-labwc-setup
once to write their labwc configuration, the ~/.bashrc.d hook that starts the
session and, through sudo, the rules for switching TTYs and logging in
automatically.

%install
cp -a %{stagedir}/. %{buildroot}/

%post
if [ "$1" -eq 1 ]; then
    echo "retrobox-labwc: each user runs 'retrobox-labwc-setup --tty N --autologin' once"
    echo "retrobox-labwc: (and again after an upgrade, to refresh ~/.config/labwc)."
fi
:

%postun
# On removal (not upgrade), drop what retrobox-labwc-setup added to /etc for
# every user: it is useless without the package.
if [ "$1" -eq 0 ]; then
    rm -f /etc/sudoers.d/retrobox-labwc-*
    for dropin in /etc/systemd/system/getty@tty*.service.d/retrobox-autologin.conf; do
        [ -e "${dropin}" ] || continue
        rm -f "${dropin}"
        rmdir "$(dirname "${dropin}")" 2>/dev/null || :
    done
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload >/dev/null 2>&1 || :
    fi
fi
:

%files
/opt/retrobox/labwc
/usr/bin/retrobox-enter-tty
/usr/bin/retrobox-exit-tty
/usr/bin/retrobox-labwc-session
/usr/bin/retrobox-labwc-setup
%license /usr/share/doc/retrobox-labwc/copyright

%changelog
* @CHANGELOG_DATE@ Manu Romero <manu4.2012@gmail.com> - @VERSION@-1
- Automated build
