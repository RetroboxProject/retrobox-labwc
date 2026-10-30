#!/usr/bin/env bash
# retrobox-labwc installer: puts the labwc gaming session next to an
# existing retrobox-core installed with its own install.sh (the .deb/.rpm
# packages need no script). Two ways to run it:
#
#   * from retrobox-core's installer, as one of its components:
#       curl -fsSL https://github.com/RetroboxProject/retrobox-core/releases/latest/download/install.sh | bash -s -- --with labwc
#     which also brings it back on every core update and removes it with
#     the core (see "Components" in that script);
#   * on its own, after retrobox-core:
#       curl -fsSL https://raw.githubusercontent.com/RetroboxProject/retrobox-labwc/HEAD/install.sh | bash -s -- --setup -- --tty 8 --autologin
#
# Options:
#   --prefix DIR      retrobox-core's install prefix; this goes to DIR/labwc
#                     (default: where the `retrobox` command points, else
#                     /opt/retrobox)
#   --bin-dir DIR     where the commands are linked (default /usr/local/bin,
#                     ~/.local/bin with --user)
#   --user            no root: everything under $HOME (no passwordless TTY
#                     switching then: go2tty must be root-owned for that)
#   --version X.Y.Z   install that release instead of the latest
#   --tarball FILE    install from a local retrobox-labwc-all.tar.gz
#                     (or RETROBOX_LABWC_TARBALL=FILE in the environment,
#                     handy through retrobox-core's installer)
#   --base-url URL    download from URL instead of the GitHub release
#                     (or RETROBOX_LABWC_BASE_URL=URL)
#   --no-deps         don't install system dependencies
#   --setup [-- ARGS] then run retrobox-labwc-setup ARGS as the user who
#                     plays (the one behind sudo, if any)
#   --uninstall       remove what this script installed
#   -h, --help
#
# After installing, every user who plays runs retrobox-labwc-setup once
# (--setup does it for you).
set -euo pipefail

REPO="RetroboxProject/retrobox-labwc"
ASSET="retrobox-labwc-all.tar.gz"
NAME="labwc"

PREFIX="${RETROBOX_PREFIX:-}"
BIN_DIR="${RETROBOX_BIN_DIR:-}"
USER_MODE=0
VERSION=""
TARBALL="${RETROBOX_LABWC_TARBALL:-}"
BASE_URL="${RETROBOX_LABWC_BASE_URL:-}"
DO_DEPS=1
UNINSTALL=0
SETUP=0
declare -a SETUP_ARGS=()
# retrobox-core's installer passes RETROBOX_PREFIX: it then owns the
# component bookkeeping (<prefix>/.components/labwc).
CALLED_BY_CORE=0
[[ -n "${RETROBOX_PREFIX:-}" ]] && CALLED_BY_CORE=1

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then B=$'\033[1m'; R=$'\033[0m'; else B=""; R=""; fi
info() { echo "${B}[INFO]${R} retrobox-labwc: $*"; }
ok()   { echo "${B}[ OK ]${R} retrobox-labwc: $*"; }
warn() { echo "${B}[WARN]${R} retrobox-labwc: $*" >&2; }
die()  { echo "${B}[ERR ]${R} retrobox-labwc: $*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed '$d; s/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)    PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        --bin-dir)   BIN_DIR="${2:?--bin-dir needs a directory}"; shift 2 ;;
        --user)      USER_MODE=1; shift ;;
        --version)   VERSION="${2:?--version needs a value}"; shift 2 ;;
        --tarball)   TARBALL="${2:?--tarball needs a file}"; shift 2 ;;
        --base-url)  BASE_URL="${2:?--base-url needs a URL}"; shift 2 ;;
        --no-deps)   DO_DEPS=0; shift ;;
        --setup)     SETUP=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --)          shift; SETUP_ARGS=("$@"); break ;;
        -h|--help)   usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

[[ "$(uname -s)" == "Linux" ]] || die "Linux only."

# --- privileges --------------------------------------------------------------
if [[ "${USER_MODE}" -eq 1 ]]; then
    priv() { "$@"; }
    HAVE_ROOT=0
elif [[ "${EUID}" -eq 0 ]]; then
    priv() { "$@"; }
    HAVE_ROOT=1
elif command -v sudo >/dev/null 2>&1; then
    priv() { sudo "$@"; }
    HAVE_ROOT=1
else
    die "Not root and no sudo available: use --user."
fi

# --- layout -------------------------------------------------------------------
# retrobox-core's prefix: where its `retrobox` command points to.
core_prefix() {
    local cmd dir
    cmd="$(command -v retrobox 2>/dev/null)" || return 1
    dir="$(dirname "$(dirname "$(readlink -f "${cmd}")")")"
    [[ -x "${dir}/bin/retrobox" ]] && echo "${dir}"
}

if [[ -z "${PREFIX}" ]]; then
    if ! PREFIX="$(core_prefix)"; then
        if [[ "${USER_MODE}" -eq 1 ]]; then PREFIX="${HOME}/.local/opt/retrobox"
        elif [[ -d /var/opt/retrobox && ! -d /opt/retrobox ]]; then PREFIX="/var/opt/retrobox"
        else PREFIX="/opt/retrobox"; fi
    fi
fi
if [[ -z "${BIN_DIR}" ]]; then
    if [[ "${USER_MODE}" -eq 1 ]]; then BIN_DIR="${HOME}/.local/bin"; else BIN_DIR="/usr/local/bin"; fi
fi
PREFIX="$(realpath -m "${PREFIX}")"
case "${PREFIX}" in
    /|/usr|/usr/*|/etc|/etc/*|/home|"${HOME}") die "Refusing to install into ${PREFIX}." ;;
esac
COMP_DIR="${PREFIX}/${NAME}"
MANIFEST="${COMP_DIR}/.install-manifest"

# A tree the package manager owns is not ours to replace or remove.
owned_by_package() {
    { command -v dpkg >/dev/null 2>&1 && dpkg -S "$1" >/dev/null 2>&1; } ||
        { command -v rpm >/dev/null 2>&1 && rpm -qf "$1" >/dev/null 2>&1; }
}
if [[ -e "${COMP_DIR}" ]] && owned_by_package "${COMP_DIR}"; then
    die "${COMP_DIR} belongs to the retrobox-labwc package: use your package manager."
fi

# --- uninstall ----------------------------------------------------------------
if [[ "${UNINSTALL}" -eq 1 ]]; then
    [[ -f "${MANIFEST}" ]] || die "No install found in ${COMP_DIR} (missing .install-manifest)."
    info "Removing ${COMP_DIR}..."
    while IFS= read -r f; do
        [[ -n "${f}" ]] && priv rm -f "${f}"
    done < "${MANIFEST}"
    priv rm -rf "${COMP_DIR}"
    if [[ "${CALLED_BY_CORE}" -eq 0 ]]; then
        priv rm -rf "${PREFIX}/.components/${NAME}"
    fi
    if [[ "${HAVE_ROOT}" -eq 1 ]]; then
        # What retrobox-labwc-setup added to /etc for every user: useless now.
        # shellcheck disable=SC2016  # expanded by that sh, not here
        priv sh -c 'rm -f /etc/sudoers.d/retrobox-labwc-*
            for d in /etc/systemd/system/getty@tty*.service.d/retrobox-autologin.conf; do
                [ -e "$d" ] || continue
                rm -f "$d"; rmdir "$(dirname "$d")" 2>/dev/null || true
            done'
        [[ -d /run/systemd/system ]] && { priv systemctl daemon-reload >/dev/null 2>&1 || true; }
    fi
    ok "Removed. ~/.config/labwc and ~/.bashrc.d/64_retrobox were kept (inert without this; retrobox-labwc-setup -u removes them)."
    exit 0
fi

# --- fetch --------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fetch() {  # fetch URL DEST
    if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1"
    else die "Neither curl nor wget is installed."; fi
}

if [[ -n "${TARBALL}" ]]; then
    [[ -f "${TARBALL}" ]] || die "${TARBALL}: no such file"
    cp "${TARBALL}" "${WORK}/${ASSET}"
    [[ -f "$(dirname "${TARBALL}")/SHA256SUMS" ]] && cp "$(dirname "${TARBALL}")/SHA256SUMS" "${WORK}/SHA256SUMS"
else
    if [[ -n "${BASE_URL}" ]]; then URL="${BASE_URL%/}"
    elif [[ -n "${VERSION}" ]]; then URL="https://github.com/${REPO}/releases/download/v${VERSION#v}"
    else URL="https://github.com/${REPO}/releases/latest/download"; fi
    info "Downloading ${URL}/${ASSET}..."
    fetch "${URL}/${ASSET}" "${WORK}/${ASSET}" || die "Download failed."
    fetch "${URL}/SHA256SUMS" "${WORK}/SHA256SUMS" || die "Could not download SHA256SUMS."
fi
if [[ -f "${WORK}/SHA256SUMS" ]]; then
    (cd "${WORK}" && grep " ${ASSET}\$" SHA256SUMS | sha256sum -c --quiet -) \
        || die "Checksum mismatch for ${ASSET}."
    ok "Checksum verified."
else
    warn "No SHA256SUMS next to the tarball: not verifying it."
fi

mkdir "${WORK}/x"
tar -xzf "${WORK}/${ASSET}" -C "${WORK}/x" --strip-components=1
[[ -x "${WORK}/x/labwc/bin/retrobox-labwc-session" ]] || die "The tarball doesn't look like a retrobox-labwc release."
NEW_VERSION="$(head -n1 "${WORK}/x/labwc/VERSION" 2>/dev/null || echo unknown)"
info "Installing ${NEW_VERSION} into ${COMP_DIR}..."
[[ -x "${PREFIX}/bin/retrobox" ]] \
    || warn "retrobox-core is not in ${PREFIX}: the session will look for \`retrobox\` on PATH."

# --- dependencies ---------------------------------------------------------------
install_deps() {
    local tree="${WORK}/x/extras" pkgs rec
    if [[ -e /run/ostree-booted || "${HAVE_ROOT}" -eq 0 ]]; then
        warn "Install these with your package manager (layer them on an immutable system):"
        warn "  $(sed -e 's/#.*//' "${tree}/deps/fedora.list" | tr '\n' ' ' | tr -s ' ')"
        return
    fi
    # shellcheck source=/dev/null
    source "${tree}/deps.sh"
    if command -v apt-get >/dev/null 2>&1; then
        priv apt-get update -qq
        mapfile -t pkgs < <(deps_apt_args "${tree}/deps/debian.list")
        priv env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
        mapfile -t rec < <(deps_apt_args "${tree}/deps/recommended-debian.list")
        priv env DEBIAN_FRONTEND=noninteractive apt-get install -y "${rec[@]}" \
            || warn "Some recommended packages could not be installed."
    elif command -v dnf >/dev/null 2>&1; then
        mapfile -t pkgs < <(deps_list "${tree}/deps/fedora.list")
        priv dnf install -y "${pkgs[@]}"
        mapfile -t rec < <(deps_list "${tree}/deps/recommended-fedora.list")
        priv dnf install -y --setopt=strict=0 "${rec[@]}" || warn "Some recommended packages could not be installed."
    else
        warn "No apt or dnf: install labwc, wlr-randr, wireplumber (wpctl), pactl, chvt, pgrep, dbus-run-session and sudo yourself."
    fi
}
[[ "${DO_DEPS}" -eq 1 ]] && install_deps

# --- install the tree (swap in, keep the old one until the new one is in place) --
OLD_MANIFEST="${WORK}/old-manifest"
: > "${OLD_MANIFEST}"
[[ -f "${MANIFEST}" ]] && cp "${MANIFEST}" "${OLD_MANIFEST}"

priv mkdir -p "${PREFIX}"
STAGING="${COMP_DIR}.new.$$"
priv rm -rf "${STAGING}"
priv cp -a "${WORK}/x/labwc" "${STAGING}"
if [[ "${HAVE_ROOT}" -eq 1 ]]; then priv chown -R root:root "${STAGING}"; fi
# Readable by every user, writable by nobody else: go2tty is run through sudo.
priv chmod -R a+rX,go-w "${STAGING}"
if [[ -e "${COMP_DIR}" ]]; then
    priv rm -rf "${COMP_DIR}.old.$$"
    priv mv "${COMP_DIR}" "${COMP_DIR}.old.$$"
fi
priv mv "${STAGING}" "${COMP_DIR}"
priv rm -rf "${COMP_DIR}.old.$$"

# --- commands -------------------------------------------------------------------
: > "${WORK}/manifest"
priv mkdir -p "${BIN_DIR}"
for cmd in "${COMP_DIR}"/bin/*; do
    link="${BIN_DIR}/$(basename "${cmd}")"
    priv ln -sfn "${cmd}" "${link}"
    echo "${link}" >> "${WORK}/manifest"
done
# Commands of the previous version that are gone now.
while IFS= read -r f; do
    [[ -n "${f}" ]] && ! grep -qxF "${f}" "${WORK}/manifest" && priv rm -f "${f}"
done < "${OLD_MANIFEST}"
priv install -m 644 "${WORK}/manifest" "${MANIFEST}"

# --- register with a script-installed retrobox-core --------------------------------
# So that its updates bring this back and its --uninstall removes it. (When
# retrobox-core runs this script, it does that itself.)
if [[ "${CALLED_BY_CORE}" -eq 0 && -f "${PREFIX}/.install-manifest" ]]; then
    self="${WORK}/self.sh"
    if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        cp "${BASH_SOURCE[0]}" "${self}"
    else  # piped into bash: fetch a copy of this script
        fetch "https://raw.githubusercontent.com/${REPO}/HEAD/install.sh" "${self}" || self=""
    fi
    if [[ -n "${self}" ]]; then
        priv mkdir -p "${PREFIX}/.components/${NAME}"
        priv install -m 755 "${self}" "${PREFIX}/.components/${NAME}/install.sh"
        printf '\n' > "${WORK}/source"
        priv install -m 644 "${WORK}/source" "${PREFIX}/.components/${NAME}/source"
        info "Registered as a component of retrobox-core in ${PREFIX}."
    fi
fi

ok "${NEW_VERSION} installed in ${COMP_DIR}."
[[ ":${PATH}:" == *":${BIN_DIR}:"* ]] || warn "${BIN_DIR} is not in your PATH."

# --- per-user setup ---------------------------------------------------------------
SETUP_CMD="${COMP_DIR}/bin/retrobox-labwc-setup"
if [[ "${SETUP}" -eq 1 ]]; then
    if [[ "${EUID}" -ne 0 ]]; then
        "${SETUP_CMD}" "${SETUP_ARGS[@]}"
    elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        sudo -u "${SUDO_USER}" -H -- "${SETUP_CMD}" "${SETUP_ARGS[@]}"
    else
        warn "--setup: run as root without sudo, so there is no user to set up."
        warn "Each user who plays runs: retrobox-labwc-setup --tty N --autologin"
    fi
else
    info "Each user who plays runs once: retrobox-labwc-setup --tty N --autologin"
fi
