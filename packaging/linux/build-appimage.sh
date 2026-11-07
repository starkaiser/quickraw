#!/usr/bin/env bash
# ==================================================================================================
# QuickRAW - build the Linux release: QuickRAW-<version>-x86_64.AppImage
#
#     packaging/linux/build-appimage.sh
#
# Needs: gfortran, gcc, make, pkg-config, libraw-dev and the X11/OpenGL headers raylib uses
# (Debian/Ubuntu/Mint: sudo apt install gfortran libraw-dev libx11-dev libxrandr-dev \
#  libxinerama-dev libxcursor-dev libxi-dev libgl1-mesa-dev pkg-config).
# linuxdeploy is downloaded on first use. Build on the oldest distribution you want to support:
# the AppImage runs on systems with the same or a newer glibc.
#
# Output: dist/QuickRAW-<version>-x86_64.AppImage
# ==================================================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

packaging/fetch-deps.sh

VERSION="$(tr -d '[:space:]' < VERSION)"
JOBS="$(nproc 2>/dev/null || echo 4)"
TOOLS="build/tools"
APPDIR="build/AppDir"

make RELEASE=1 BACKEND=threads -j"$JOBS" ${GFORTRAN:+GFORTRAN="$GFORTRAN"}

mkdir -p "$TOOLS"
LINUXDEPLOY="${LINUXDEPLOY:-$TOOLS/linuxdeploy-x86_64.AppImage}"
if [ ! -x "$LINUXDEPLOY" ]; then
    curl -fsSL -o "$LINUXDEPLOY" \
        https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
    chmod +x "$LINUXDEPLOY"
fi

rm -rf "$APPDIR"
install -Dm755 quickraw "$APPDIR/usr/bin/quickraw"
install -Dm644 packaging/linux/quickraw.desktop "$APPDIR/usr/share/applications/quickraw.desktop"
for size in 64 256 512; do
    install -Dm644 "packaging/icons/quickraw-$size.png" \
        "$APPDIR/usr/share/icons/hicolor/${size}x${size}/apps/quickraw.png"
done

# Works without FUSE too (containers, CI).
export APPIMAGE_EXTRACT_AND_RUN=1
export LINUXDEPLOY_OUTPUT_VERSION="$VERSION"
export ARCH=x86_64
"$LINUXDEPLOY" --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/quickraw" \
    --desktop-file "$APPDIR/usr/share/applications/quickraw.desktop" \
    --icon-file "packaging/icons/quickraw-256.png" --icon-filename quickraw \
    --output appimage

mkdir -p dist
mv -f QuickRAW-*"$VERSION"*-x86_64.AppImage "dist/QuickRAW-${VERSION}-x86_64.AppImage"
echo "--- built dist/QuickRAW-${VERSION}-x86_64.AppImage ($(du -h "dist/QuickRAW-${VERSION}-x86_64.AppImage" | cut -f1))"
