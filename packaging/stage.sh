#!/usr/bin/env bash
# Stage retrobox-labwc's installation tree into DESTDIR (used by the .deb,
# the .rpm and the install.sh tarball).
#
#   packaging/stage.sh DESTDIR
#
# Layout produced (paths are relative to DESTDIR):
#   ${INSTALL_ROOT}/           the component: bin/ libexec/ share/ VERSION
#                              (default /opt/retrobox/labwc, next to
#                              retrobox-core in /opt/retrobox)
#   ${BIN_DIR}/<command>       symlinks to ${INSTALL_ROOT}/bin/<command>
#   /usr/share/doc/retrobox-labwc/copyright
#
# Environment: PKG_VERSION   written to ${INSTALL_ROOT}/VERSION (default: git describe)
#
# The file list comes from `git ls-files`, so only tracked files are shipped.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
DESTDIR="${1:?usage: $(basename "$0") DESTDIR}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/retrobox/labwc}"
BIN_DIR="${BIN_DIR:-/usr/bin}"

if [[ -e "${DESTDIR}" ]] && [[ -n "$(ls -A "${DESTDIR}" 2>/dev/null)" ]]; then
    echo "stage.sh: ${DESTDIR} exists and is not empty" >&2
    exit 1
fi
ROOT_IN_PKG="${DESTDIR}${INSTALL_ROOT}"
mkdir -p "${ROOT_IN_PKG}"

# --- 1. The tree: what runs, nothing else ------------------------------------
git -C "${SRC}" ls-files -z -- bin libexec share \
    | tar --null -C "${SRC}" -T - -cf - \
    | tar -xf - -C "${ROOT_IN_PKG}"

echo "${PKG_VERSION:-$(git -C "${SRC}" describe --tags --always 2>/dev/null || echo unknown)}" \
    > "${ROOT_IN_PKG}/VERSION"

# Normalise modes: directories 755, executables 755, everything else 644.
# (go2tty is run as root through sudo: it must not be writable by anyone else,
# and the whole tree ends up owned by root.)
find "${ROOT_IN_PKG}" -type d -exec chmod 755 {} +
find "${ROOT_IN_PKG}" -type f -perm /111 -exec chmod 755 {} +
find "${ROOT_IN_PKG}" -type f ! -perm /111 -exec chmod 644 {} +

# --- 2. Commands ----------------------------------------------------------------
mkdir -p "${DESTDIR}${BIN_DIR}"
for cmd in "${ROOT_IN_PKG}"/bin/*; do
    ln -s "${INSTALL_ROOT}/bin/$(basename "${cmd}")" "${DESTDIR}${BIN_DIR}/$(basename "${cmd}")"
done

# --- 3. Licence -----------------------------------------------------------------
mkdir -p "${DESTDIR}/usr/share/doc/retrobox-labwc"
install -m 644 "${SRC}/LICENSE" "${DESTDIR}/usr/share/doc/retrobox-labwc/copyright"
