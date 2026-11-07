#!/usr/bin/env bash
# ==================================================================================================
# QuickRAW - fetch the third-party sources into lib/ if they are not there yet.
#
#   lib/fortran-raylib   interkosmos/fortran-raylib (pinned commit)
#   lib/raylib-6.0       raysan5/raylib 6.0
#
# Used by the packaging scripts and CI; safe to run any time (it never
# overwrites an existing folder).
# ==================================================================================================
set -euo pipefail

FORTRAN_RAYLIB_URL="https://github.com/interkosmos/fortran-raylib.git"
FORTRAN_RAYLIB_COMMIT="7745b0779c164a86b9c29ca7d29a44c70f74e143"
RAYLIB_URL="https://github.com/raysan5/raylib.git"
RAYLIB_VERSION="6.0"

cd "$(dirname "$0")/.."
mkdir -p lib

if [ ! -f lib/fortran-raylib/src/raylib.F90 ]; then
    echo "--- fetching fortran-raylib ${FORTRAN_RAYLIB_COMMIT:0:7}"
    rm -rf lib/fortran-raylib
    git clone --quiet "$FORTRAN_RAYLIB_URL" lib/fortran-raylib
    git -C lib/fortran-raylib checkout --quiet "$FORTRAN_RAYLIB_COMMIT"
fi

if [ ! -f "lib/raylib-${RAYLIB_VERSION}/src/raylib.h" ]; then
    echo "--- fetching raylib ${RAYLIB_VERSION}"
    rm -rf "lib/raylib-${RAYLIB_VERSION}"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$RAYLIB_VERSION" "$RAYLIB_URL" "lib/raylib-${RAYLIB_VERSION}"
fi

echo "--- dependencies ready"
