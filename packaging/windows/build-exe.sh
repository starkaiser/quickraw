#!/usr/bin/env bash
# ==================================================================================================
# QuickRAW - build the Windows release: one self-contained .exe
#
# Run in an MSYS2 "UCRT64" shell (https://www.msys2.org):
#
#     packaging/windows/build-exe.sh            installs the build tools with pacman, then builds
#     packaging/windows/build-exe.sh --no-deps  skip pacman (CI installs them up front)
#
# Output: dist/QuickRAW-<version>-windows-x64.exe
#
# Everything (gfortran runtime, OpenMP, LibRaw, lcms2, libjpeg, zlib, raylib, fonts, icon)
# is linked statically, so the .exe runs on any Windows 10/11 x64 PC without installing anything.
# ==================================================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ "${MSYSTEM:-}" != "UCRT64" ] && [ "${MSYSTEM:-}" != "MINGW64" ]; then
    echo "Please run this from an MSYS2 UCRT64 (or MINGW64) shell." >&2
    exit 1
fi
PREFIX="mingw-w64-ucrt-x86_64"
[ "${MSYSTEM}" = "MINGW64" ] && PREFIX="mingw-w64-x86_64"

if [ "${1:-}" != "--no-deps" ]; then
    pacman -S --needed --noconfirm make git \
        "$PREFIX-gcc" "$PREFIX-gcc-fortran" "$PREFIX-pkgconf" \
        "$PREFIX-libraw" "$PREFIX-lcms2" "$PREFIX-libjpeg-turbo" "$PREFIX-zlib"
fi

packaging/fetch-deps.sh

VERSION="$(tr -d '[:space:]' < VERSION)"
JOBS="$(nproc 2>/dev/null || echo 4)"

make RELEASE=1 BACKEND=threads CC=gcc -j"$JOBS"

mkdir -p dist
OUT="dist/QuickRAW-${VERSION}-windows-x64.exe"
cp quickraw.exe "$OUT"
strip "$OUT"

# The .exe must only depend on DLLs that ship with Windows.
echo "--- DLL imports of $OUT"
objdump -p "$OUT" | awk '/DLL Name/ {print "    " $3}'
if objdump -p "$OUT" | awk '/DLL Name/ {print tolower($3)}' | \
        grep -v -E '^(kernel32|user32|gdi32|shell32|ole32|oleaut32|comdlg32|winmm|opengl32|advapi32|ws2_32|msvcrt|ucrtbase|api-ms-win-.*|bcrypt|imm32|dwmapi|shcore|uxtheme|version|winspool|comctl32|setupapi|cfgmgr32|hid|rpcrt4|ntdll|uuid)\.dll$'; then
    echo "Error: the .exe needs non-system DLLs (listed above)." >&2
    exit 1
fi

echo "--- built $OUT ($(du -h "$OUT" | cut -f1))"
