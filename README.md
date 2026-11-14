# retrobox-labwc

The labwc gaming session of [Retrobox](https://github.com/RetroboxProject/retrobox-core), for **minimal systems** (Debian netinstall, Arch, ...): the machine logs in on a TTY by itself, starts [labwc](https://labwc.github.io) there and Retrobox runs inside it. No desktop, no display manager.

It is a single user-level installer: no root, no packages. It checks what the system must already have and sets up the rest inside your home.

- **Win+P** switches the display output (internal panel ⇄ external screen) and **Win+O** the audio output.
- **Win+Shift+R** restarts the session (it re-reads the system keyboard), **Win+Shift+E** exits labwc and ends it.
- The volume keys, **Print** (Retrobox screenshot), **Alt+Tab**, **Alt+F4** and **Win+T** (terminal) work as usual.

Retrobox ending closes labwc, and you are left at the shell prompt of that TTY (log out for a fresh autologin).

## Requirements

Installed by you, with your package manager (`./install.sh --check --tty N` tells you which):

| | Debian | Arch |
|---|---|---|
| labwc | `labwc` | `labwc` |
| pipewire-pulse | `pipewire-pulse` | `pipewire-pulse` |
| a terminal | `foot` (or `alacritty`) | `foot` |
| dbus-run-session | `dbus-bin` | `dbus` |
| recommended | `wlr-randr wireplumber pulseaudio-utils xwayland` | `wlr-randr wireplumber libpulse xorg-xwayland` |

plus `retrobox-core`, and systemd with a `getty` autologin on the gaming TTY. The installer **checks** the autologin and, if it is missing, prints the drop-in to create (that part is system-wide, so it is yours to do):

```bash
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<'CONF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin YOUR_USER --noclear %I $TERM
CONF
sudo systemctl daemon-reload
```

## Install

```bash
git clone https://github.com/RetroboxProject/retrobox-labwc && cd retrobox-labwc
./install.sh --tty 1        # --check --tty 1 only checks; --force installs even if a check fails
```

Everything lands in your home:

- `~/.local/share/retrobox-labwc`: a copy of this tree (the checkout can go) and `retrobox-labwc-session` linked in `~/.local/bin`
- `~/.config/retrobox-labwc`: labwc's config for the session (`labwc -C`); your `~/.config/labwc` is never touched
- `~/.config/retrobox/retrobox.ini.d/50-labwc.ini`: `[advanced] labwc_tty`
- a block in your login profile (`~/.bash_profile`, `~/.bash_login` or `~/.profile`, whichever bash reads) that starts the session when the gaming TTY logs in

**The TTY is fixed once installed.** To change it: `~/.local/share/retrobox-labwc/install.sh --uninstall`, then install again. Running the installer again with the same TTY just updates.

`--uninstall` removes all of the above (and restores your profile). It leaves the getty autologin alone, since it lives in `/etc`.

## Keyboard

The session always uses the system's keyboard: `/etc/default/keyboard` (Debian's `keyboard-configuration`), else `localectl`'s X11 keymap, read every time the session starts. Nothing is copied into labwc's config. To change it on Debian:

```bash
sudo dpkg-reconfigure keyboard-configuration
```

then press **Win+Shift+R** (or log out and in again).

## Configuration

In any `retrobox.ini` layer (`/etc/retrobox`, `~/.config/retrobox`, their `retrobox.ini.d/`), only when the guess is wrong (outputs from `wlr-randr`, sinks from `pactl list short sinks`):

```ini
[labwc]
internal_output = eDP-1         ; default: the first eDP/LVDS/DSI output
external_output = HDMI-A-1      ; default: the first other output
external_sink = alsa_output.pci-0000_01_00.1.hdmi-stereo   ; default: the first hdmi/displayport sink
internal_sink = alsa_output.pci-0000_05_00.6.analog-stereo ; default: the first other sink
```

The session log is `~/.local/state/retrobox/logs/labwc-session.log`.

## Layout

```
install.sh    the installer: --check, install, --uninstall
bin/          retrobox-labwc-session
libexec/      display/audio switchers, retrobox-labwc-common.sh (settings, keyboard)
share/        labwc config templates, the login hook
tests/        smoke-test.sh (stand-in commands, throwaway HOME)
```

## License

GPLv2, like retrobox-core. See [LICENSE](LICENSE).
