# retrobox-labwc

The labwc gaming session of [Retrobox](https://github.com/RetroboxProject/retrobox-core), for **minimal systems** (Debian netinstall, Arch, ...): the machine logs in on a TTY by itself, starts [labwc](https://labwc.github.io) there and Retrobox runs inside it. No desktop, no display manager.

It is a single user-level installer: no root, no packages. It checks what the system must already have and sets up the rest inside your home.

- **Win+P** switches the display output (internal panel ⇄ external screen).
- **Win+Shift+R** restarts the session (it re-reads the system keyboard), **Win+Shift+E** exits labwc and ends it.
- The mouse pointer is parked in the bottom-right corner when the session starts (see [Mouse pointer](#mouse-pointer)). The volume keys (capped at 100%, no distorted boost), **Print** (Retrobox screenshot), **Alt+Tab**, **Alt+F4** and **Win+T** (terminal) work as usual.

Retrobox ending closes labwc, and you are left at the shell prompt of that TTY (log out for a fresh autologin).

## Requirements

Installed by you, with your package manager (`./install.sh --check --tty N` tells you which):

| | Debian | Arch |
|---|---|---|
| labwc | `labwc` | `labwc` |
| pipewire-pulse | `pipewire-pulse` | `pipewire-pulse` |
| a terminal | `foot` (or `alacritty`) | `foot` |
| dbus-run-session | `dbus-bin` | `dbus` |
| recommended | `wlr-randr wireplumber xwayland wlrctl` | `wlr-randr wireplumber xorg-xwayland wlrctl` |

plus `retrobox-core` and systemd. For any TTY but 1, `chvt` (package `kbd`) is needed too.

## Install

```bash
git clone https://github.com/RetroboxProject/retrobox-labwc && cd retrobox-labwc
./install.sh --tty 1        # --check --tty 1 only checks; --force installs even if a check fails
```

The machine should log in on the gaming TTY by itself and boot on it. If that is not so yet, the installer sets it up, and this is the only thing that needs root (it asks for your password through `sudo`; `--no-system` skips it): a drop-in `/etc/systemd/system/getty@ttyN.service.d/retrobox-labwc.conf` with the getty autologin and, for any TTY but 1, a switch to it at boot (`chvt N`), plus `systemctl enable getty@ttyN`. An autologin you already have on that TTY is kept and only completed; one for another user is never overridden. `./install.sh --check` prints what it would write.

Everything lands in your home:

- `~/.local/share/retrobox-labwc`: a copy of this tree (the checkout can go) and `retrobox-labwc-session` linked in `~/.local/bin`
- `~/.config/retrobox-labwc`: labwc's config for the session (`labwc -C`); your `~/.config/labwc` is never touched
- `~/.config/retrobox/retrobox.ini.d/50-labwc.ini`: `[advanced] labwc_tty`
- a block in your login profile (`~/.bash_profile`, `~/.bash_login` or `~/.profile`, whichever bash reads) that starts the session when the gaming TTY logs in

**The TTY is fixed once installed.** To change it: `~/.local/share/retrobox-labwc/install.sh --uninstall`, then install again. Running the installer again with the same TTY just updates.

`--uninstall` removes all of the above, restores your profile and undoes the system part (the drop-in and the `enable` it made; an autologin of your own stays).

## Keyboard

The session always uses the system's keyboard: `/etc/default/keyboard` (Debian's `keyboard-configuration`), else `localectl`'s X11 keymap, read every time the session starts. Nothing is copied into labwc's config. To change it on Debian:

```bash
sudo dpkg-reconfigure keyboard-configuration
```

then press **Win+Shift+R** (or log out and in again).

## Mouse pointer

Two small standalone scripts in `libexec/` (they need only `wlrctl`, and `wlr-randr` for the second), meant to be run by labwc's autostart and by hooks of Retrobox or anything else in the session; copy them wherever you need them:

- `mouse-hide`: parks the pointer in the bottom-right corner. labwc's autostart runs it when the session starts.
- `mouse-show`: puts the pointer in the centre of the screen.

`wlrctl` can only move the pointer relatively, so `mouse-hide` sends it far past the corner (the compositor stops it at the edge) and `mouse-show` goes to the top-left corner and then back half the size of the screen, which it reads from `wlr-randr`.

## Resolution

The session runs at whatever the kernel command line forces, and at nothing else's say. To limit it to 1280x720 at 60 Hz, add `video=CONNECTOR:1280x720@60` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub` (`sudo update-grub`, reboot); connector names are in `/sys/class/drm/card*-*/status` (e.g. `HDMI-A-2`). labwc's autostart applies that mode before Retrobox starts, and Win+P keeps it. Without a `video=`, the screen's preferred mode is used.

## Configuration

In any `retrobox.ini` layer (`/etc/retrobox`, `~/.config/retrobox`, their `retrobox.ini.d/`), only when the guess is wrong (outputs from `wlr-randr`):

```ini
[labwc]
internal_output = eDP-1         ; default: the first eDP/LVDS/DSI output
external_output = HDMI-A-1      ; default: the first other output
```

To power the machine off when Retrobox quits normally (exit status 0; a crash, Win+Shift+E or a restart never does), in any layer:

```ini
[labwc]
on_quit = poweroff              ; default: shell (you are left at the prompt)
```

It runs `systemctl poweroff` as your user, which needs polkit on a minimal system (`polkitd`, which lets the active local session power off); check it with `systemctl poweroff` from a shell on the gaming TTY before relying on it.

The session log is `~/.local/state/retrobox/logs/labwc-session.log`.

## Layout

```
install.sh    the installer: --check, install, --uninstall
bin/          retrobox-labwc-session
libexec/      display switcher, mouse-hide, mouse-show, retrobox-labwc-common.sh (settings, keyboard)
share/        labwc config templates, the login hook
tests/        smoke-test.sh (stand-in commands, throwaway HOME)
```

## License

GPLv2, like retrobox-core. See [LICENSE](LICENSE).
