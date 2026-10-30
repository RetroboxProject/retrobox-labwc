# retrobox-labwc

The labwc gaming session of [Retrobox](https://github.com/RetroboxProject/retrobox-core): Retrobox runs inside a [labwc](https://labwc.github.io) Wayland session on a virtual terminal of its own, isolated from the desktop session (separate D-Bus session), so a game never fights with Plasma (or whatever desktop you use) for the screen.

- `retrobox-enter-tty` (from the desktop) switches to the gaming TTY; its autologin shell starts labwc and Retrobox side by side.
- **Win+D** goes back to the desktop and leaves the session running; quitting Retrobox closes labwc and returns to the desktop by itself.
- **Win+P** switches the display output (internal panel ⇄ external screen) and **Win+O** the audio output; the volume keys, **Print** (Retrobox screenshot), **Alt+Tab**, **Alt+F4** and **Win+T** (terminal) work as usual.

It is a component of `retrobox-core` and needs it installed.

## Install

**Debian / Ubuntu (.deb)** and **Fedora (.rpm)**, from the [releases](https://github.com/RetroboxProject/retrobox-labwc/releases) (one package for every architecture):

```bash
sudo apt install ./retrobox-labwc_<version>_all.deb
sudo dnf install ./retrobox-labwc-<version>-1.noarch.rpm
```

**install.sh**, together with a script-installed `retrobox-core` (it is then updated with the core and removed with it):

```bash
curl -fsSL https://github.com/RetroboxProject/retrobox-core/releases/latest/download/install.sh | bash -s -- --with labwc
```

or on its own, next to an existing `retrobox-core`, setting up the current user at the same time:

```bash
curl -fsSL https://raw.githubusercontent.com/RetroboxProject/retrobox-labwc/HEAD/install.sh | bash -s -- --setup -- --tty 8 --autologin
# options: --prefix DIR  --bin-dir DIR  --user  --version X.Y.Z  --tarball FILE  --no-deps  --setup [-- ARGS]  --uninstall
```

Everything lands in `<retrobox-core prefix>/labwc` (`/opt/retrobox/labwc`), with the commands in `/usr/bin` (packages) or `/usr/local/bin` (install.sh).

### Per-user setup

The package only puts files on the system. Each user who plays runs, once (and again after an upgrade):

```bash
retrobox-labwc-setup --tty 8 --autologin
```

- `--tty N` picks the gaming VT: it writes `[advanced] labwc_tty = N` to `~/.config/retrobox/retrobox.ini.d/50-labwc.ini` (any `retrobox.ini` layer works, as in retrobox-core).
- renders `rc.xml`, `autostart` and `environment` (with this install's paths and the system keyboard layout) into `~/.config/labwc` and links `themerc-override`; files of yours it would replace are kept as `*.bak-<date>`.
- installs `~/.bashrc.d/64_retrobox`, the hook that starts the session from the gaming TTY's autologin shell. Debian's default `~/.bashrc` doesn't read `~/.bashrc.d`; the script tells you the line to add.
- through `sudo`: lets you run `go2tty` (the VT switcher, which needs root) without a password, with a rule for exactly that file, and with `--autologin` makes the gaming TTY log you in (a drop-in for `getty@ttyN.service`).
- `--no-system` does only the per-user part; `-u` undoes everything.

The passwordless rule is only written when `go2tty` and every directory above it belong to root and nobody else can write to them (packages and a root `install.sh`): with `--user` or from a git checkout, switching TTYs asks for your password instead.

## Configuration

In any `retrobox.ini` layer (`/etc/retrobox`, `~/.config/retrobox`, their `retrobox.ini.d/`):

```ini
[advanced]
labwc_tty = 8                   ; the gaming VT (1-12)

[labwc]
; only when the guess is wrong (outputs from `wlr-randr`, sinks from `pactl list short sinks`)
internal_output = eDP-1         ; default: the first eDP/LVDS/DSI output
external_output = HDMI-A-1      ; default: the first other output
external_sink = alsa_output.pci-0000_01_00.1.hdmi-stereo   ; default: the first hdmi/displayport sink
internal_sink = alsa_output.pci-0000_05_00.6.analog-stereo ; default: the first other sink
```

The session log is `~/.local/state/retrobox/logs/labwc-session.log`.

## Layout

```
bin/          commands: retrobox-enter-tty, retrobox-exit-tty, retrobox-labwc-session, retrobox-labwc-setup
libexec/      go2tty (run as root through sudo), display/audio switchers, retrobox-labwc-common.sh
share/        labwc config templates, the ~/.bashrc.d hook template
deps/         dependency lists (Debian, Fedora): the packages' Depends and install.sh's single source
packaging/    stage.sh, deb/, rpm/, tarball/, smoke-test.sh
install.sh    standalone / retrobox-core component installer
```

## Building

```bash
packaging/deb/build-deb.sh           # dist/retrobox-labwc_<version>_all.deb
packaging/rpm/build-rpm.sh           # dist/retrobox-labwc-<version>-1.noarch.rpm (needs rpmbuild)
packaging/tarball/build-tarball.sh   # dist/retrobox-labwc-all.tar.gz + SHA256SUMS (the install.sh payload)
```

Versions come from the tags (`vX.Y.Z` → `X.Y.Z`, otherwise `<last tag>+git<date>.<sha>`). The GitHub Actions workflow lints the scripts with shellcheck, builds the three, tests the packages in Ubuntu 24.04, Debian 13 and Fedora containers (against a stand-in `retrobox-core`) and `install.sh` next to a script-installed core and, for `v*` tags, publishes them with `install.sh` and `SHA256SUMS` as a release.

## License

GPLv2, like retrobox-core. See [LICENSE](LICENSE).
