#!/usr/bin/env bash
# Build the install.sh payload: retrobox-labwc-all.tar.gz (+ SHA256SUMS).
#
#   packaging/tarball/build-tarball.sh [--version VERSION] [--outdir DIR]
#
# Same file set as the packages (it comes from packaging/stage.sh):
#
#   labwc/               the component tree (-> <prefix>/labwc)
#   extras/deps/*.list, extras/deps.sh
#                        what install.sh needs to bring the dependencies; they
#                        are not part of the installed tree
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
SRC="$(cd "${HERE}/../.." >/dev/null 2>&1 && pwd -P)"

VERSION=""
OUTDIR="${SRC}/dist"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --outdir)  OUTDIR="${2:?--outdir needs a value}"; shift 2 ;;
        -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

. "${SRC}/packaging/version.sh"
[[ -n "${VERSION}" ]] || VERSION="$(derive_version "${SRC}")"

SOURCE_DATE_EPOCH="$(git -C "${SRC}" log -1 --format=%ct)"
export SOURCE_DATE_EPOCH

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STAGE="${WORK}/stage"
TOP="${WORK}/retrobox-labwc-all"

PKG_VERSION="${VERSION}" "${SRC}/packaging/stage.sh" "${STAGE}" >/dev/null

mkdir -p "${TOP}/extras/deps"
mv "${STAGE}/opt/retrobox/labwc" "${TOP}/labwc"
# No /usr/share/doc outside a package: the licence travels with the tree.
cp "${SRC}/LICENSE" "${TOP}/labwc/LICENSE"
cp "${SRC}"/deps/*.list "${TOP}/extras/deps/"
cp "${SRC}/deps/deps.sh" "${TOP}/extras/deps.sh"

mkdir -p "${OUTDIR}"
OUT="${OUTDIR}/retrobox-labwc-all.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@${SOURCE_DATE_EPOCH}" -C "${WORK}" -cf - retrobox-labwc-all \
    | gzip -n -9 > "${OUT}"
(cd "${OUTDIR}" && sha256sum retrobox-labwc-all.tar.gz > SHA256SUMS)

echo "build-tarball.sh: built ${OUT} (version ${VERSION})"
