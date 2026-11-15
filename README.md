# retrobox-labwc

The labwc gaming session of [Retrobox](https://github.com/RetroboxProject/retrobox-core), for **minimal systems** (Debian netinstall, Arch, ...): the machine boots on a TTY, where a systemd service starts [labwc](https://labwc.github.io) and Retrobox runs inside it. No desktop, no display manager, no autologin.

It is a single installer: it installs no packages, it checks what the system must already have and sets up the rest (your home, plus one service and one polkit rule through `sudo`).

The session is an ordinary service, so you can manage it from anywhere, ssh included:

```bash
systemctl stop retrobox-labwc      # bare system: the TTY gets its login prompt back
systemctl start retrobox-labwc     # the gaming session again
systemctl restart retrobox-labwc   # start over (e.g. after a keyboard change)
```

- **Win+P** switches the display output (internal panel ⇄ external screen).
- **Win+Shift+R** restarts the session (it re-reads the system keyboard), **Win+Shift+E** exits labwc and ends it.
- The mouse pointer is parked in the bottom-right corner when the session starts (see [Mouse pointer](#mouse-pointer)). The volume keys (capped at 100%, no distorted boost), **Print** (Retrobox screenshot), **Alt+Tab**, **Alt+F4** and **Win+T** (terminal) work as usual.

Retrobox ending closes labwc; unless the machine is set to power off, the service ends and the TTY shows its login prompt.

## Requirements

Installed by you, with your package manager (`./install.sh --check --tty N` tells you which):

| | Debian | Arch |
|---|---|---|
| labwc | `labwc` | `labwc` |
| pipewire-pulse | `pipewire-pulse` | `pipewire-pulse` |
| a terminal | `foot` (or `alacritty`) | `foot` |
| dbus-run-session | `dbus-bin` | `dbus` |
| user bus (recommended) | `dbus-user-session` | `dbus` |
| recommended | `wlr-randr wireplumber xwayland wlrctl pulseaudio-utils` | `wlr-randr wireplumber xorg-xwayland wlrctl libpulse` |

plus `retrobox-core`, systemd and PAM (`libpam-systemd` on Debian). For any TTY but 1, `chvt` (package `kbd`) is needed too.

## Install

```bash
git clone https://github.com/RetroboxProject/retrobox-labwc && cd retrobox-labwc
./install.sh --tty 1        # --check --tty 1 only checks; --force installs even if a check fails
```

The installer needs root for two files only (it asks for your password through `sudo`; `--no-system` skips both): `/etc/systemd/system/retrobox-labwc.service`, enabled at boot, and the polkit rule below (`--no-polkit` skips just the rule). The service takes the gaming TTY over from its getty (`Conflicts=getty@ttyN`), logs your user in through PAM (a real logind session, which labwc needs), switches to that VT (`chvt N`) and runs the session from a login shell, so your `PATH` is the one of your profile. When it ends, however it ends, the getty comes back. `./install.sh --check` prints the unit it would write.

Everything lands in your home:

- `~/.local/share/retrobox-labwc`: a copy of this tree (the checkout can go) and `retrobox-labwc-session` linked in `~/.local/bin`
- `~/.config/retrobox-labwc`: labwc's config for the session (`labwc -C`); your `~/.config/labwc` is never touched
- `~/.config/retrobox/retrobox.ini.d/50-labwc.ini`: `[advanced] labwc_tty`

**The TTY is fixed once installed.** To change it: `~/.local/share/retrobox-labwc/install.sh --uninstall`, then install again. Running the installer again with the same TTY just updates.

`--uninstall` removes all of the above and the system part (service and rule). A session that is still running keeps running until `systemctl stop retrobox-labwc` or a reboot. An install of the previous version (login hook plus autologin drop-in) is migrated by simply running the installer again.

## Keyboard

The session always uses the system's keyboard: `/etc/default/keyboard` (Debian's `keyboard-configuration`), else `localectl`'s X11 keymap, read every time the session starts. Nothing is copied into labwc's config. To change it on Debian:

```bash
sudo dpkg-reconfigure keyboard-configuration
```

then press **Win+Shift+R** (or `systemctl restart retrobox-labwc`).

## Mouse pointer

Two small standalone scripts in `libexec/` (they need only `wlrctl`, and `wlr-randr` for the second), meant to be run by labwc's autostart and by hooks of Retrobox or anything else in the session; copy them wherever you need them:

- `mouse-hide`: parks the pointer in the bottom-right corner. labwc's autostart runs it when the session starts.
- `mouse-show`: puts the pointer in the centre of the screen.

`wlrctl` can only move the pointer relatively, so `mouse-hide` sends it far past the corner (the compositor stops it at the edge) and `mouse-show` goes to the top-left corner and then back half the size of the screen, which it reads from `wlr-randr`.

## Headphones

`libexec/retrobox-audio-jack` (started by the session) keeps the audio card on its **analog duplex** profile while headphones are plugged into the jack and on **HDMI** while they are not (analog if there is no HDMI profile available). PipeWire reports the jack but keeps the analog profile available without headphones, so it never leaves it by itself. It reacts to the card events of the audio server (`pactl subscribe`) and needs `pactl`. It only acts when what it wants changes (headphones plugged or unplugged, an HDMI profile becoming available, the session starting): a profile chosen by hand meanwhile, such as from the overlay's audio page or pavucontrol, is left alone until the next change. Other profile names (`pactl list cards` shows them) go in `~/.config/retrobox-labwc/environment`:

```
RETROBOX_AUDIO_HEADPHONES_PROFILE=output:analog-stereo+input:analog-stereo
RETROBOX_AUDIO_HDMI_PROFILE=output:hdmi-stereo
```

## Resolution

The session runs at whatever the kernel command line forces, and at nothing else's say. To limit it to 1280x720 at 60 Hz, add `video=CONNECTOR:1280x720@60` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub` (`sudo update-grub`, reboot); connector names are in `/sys/class/drm/card*-*/status` (e.g. `HDMI-A-2`). labwc's autostart applies that mode before Retrobox starts, and Win+P keeps it. Without a `video=`, the screen's preferred mode is used.

## Configuration

In any `retrobox.ini` layer (`/etc/retrobox`, `~/.config/retrobox`, their `retrobox.ini.d/`), only when the guess is wrong (outputs from `wlr-randr`):

```ini
[labwc]
internal_output = eDP-1         ; default: the first eDP/LVDS/DSI output
external_output = HDMI-A-1      ; default: the first other output
```

When Retrobox quits normally (exit status 0) the machine powers off; a crash, Win+Shift+E or a restart never do. That is the default of `./install.sh`; `--on-quit shell` just ends the service instead, so the TTY shows its login prompt (the choice lives in `~/.config/retrobox-labwc/on_quit`, and a re-run keeps it unless you give the option again).

`systemctl poweroff` and `reboot` (also the ones EmulationStation sends) need polkit to allow them. The installer writes `/etc/polkit-1/rules.d/50-retrobox-labwc.rules`, which lets your user power off and reboot from any session and start, stop and restart `retrobox-labwc.service` without a password (`--no-polkit` skips it, and then those need `sudo`; `--uninstall` removes it; it needs `polkitd` installed). If a reboot is already in progress when Retrobox exits, the power off does not replace it.

**D-Bus.** The session uses your user bus (`$XDG_RUNTIME_DIR/bus`, run by systemd's user manager), so portals, pipewire and wireplumber are one set shared with everything else you run, and the compositor's environment (`WAYLAND_DISPLAY`, ...) is handed to that bus while the session lasts. Without a user bus (no `dbus-user-session` on Debian) it falls back to a private one with `dbus-run-session`; `RETROBOX_LABWC_PRIVATE_BUS=1` forces that fallback.

The session log is `~/.local/state/retrobox/logs/labwc-session.log`; the service's own messages are in `journalctl -u retrobox-labwc`.

## Layout

```
install.sh    the installer: --check, install, --uninstall
bin/          retrobox-labwc-session
libexec/      display switcher, mouse-hide, mouse-show, retrobox-labwc-common.sh (settings, keyboard)
share/        labwc config templates
tests/        smoke-test.sh (stand-in commands, throwaway HOME)
```

## License

GPLv2, like retrobox-core. See [LICENSE](LICENSE).
