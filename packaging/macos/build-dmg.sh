#!/usr/bin/env bash
# ==================================================================================================
# QuickRAW - build the macOS release: QuickRAW.app inside a .dmg
#
#     packaging/macos/build-dmg.sh
#
# Needs Homebrew:  brew install gcc libraw dylibbundler pkg-config
# Builds for the Mac it runs on (Apple Silicon or Intel); the app needs that
# macOS version or newer (see MIN_MACOS below).
#
# Output: dist/QuickRAW-<version>-macos-<arm64|x86_64>.dmg
#
# Signing: by default the app is ad-hoc signed, which is enough to run it on your own Mac.
# For distribution set CODESIGN_IDENTITY="Developer ID Application: ..." and, to notarize,
# NOTARY_PROFILE=<profile created with `xcrun notarytool store-credentials`>.
# ==================================================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

packaging/fetch-deps.sh

VERSION="$(tr -d '[:space:]' < VERSION)"
ARCH="$(uname -m)"
BUNDLE_ID="${BUNDLE_ID:-io.github.quickraw.QuickRAW}"
# Homebrew bottles target the macOS they were built for, so the bundle can't
# promise more: by default the minimum is the build machine's major version.
MIN_MACOS="${MIN_MACOS:-$(sw_vers -productVersion | cut -d. -f1).0}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
BREW="$(brew --prefix)"

# Homebrew's gcc provides gfortran; raylib and the C layer use Apple clang.
GFORTRAN="${GFORTRAN:-$(command -v gfortran || ls "$BREW"/bin/gfortran-* | sort -V | tail -1)}"
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export PKG_CONFIG_PATH="$BREW/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

make RELEASE=1 BACKEND=threads GFORTRAN="$GFORTRAN" CC=clang -j"$JOBS"

APP="build/macos-app/QuickRAW.app"
rm -rf build/macos-app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp quickraw "$APP/Contents/MacOS/QuickRAW"
cp packaging/icons/quickraw.icns "$APP/Contents/Resources/quickraw.icns"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" -e "s/@MIN_MACOS@/$MIN_MACOS/g" \
    packaging/macos/Info.plist.in > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Copy the Homebrew dylibs (LibRaw, lcms2, jpeg, libgfortran, libgomp, ...) into the bundle.
GCC_LIB="$(dirname "$("$GFORTRAN" -print-file-name=libgfortran.dylib)")"
dylibbundler -od -b -x "$APP/Contents/MacOS/QuickRAW" \
    -d "$APP/Contents/Frameworks/" -p @executable_path/../Frameworks/ \
    -s "$GCC_LIB" -s "$BREW/lib"

echo "--- linked libraries"
otool -L "$APP/Contents/MacOS/QuickRAW" | tail -n +2
if otool -L "$APP/Contents/MacOS/QuickRAW" "$APP"/Contents/Frameworks/*.dylib | \
        grep -E "^\s+($BREW|/usr/local/(opt|Cellar))" ; then
    echo "Error: the app still links Homebrew libraries (listed above)." >&2
    exit 1
fi

IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"/Contents/Frameworks/*.dylib
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

mkdir -p dist
DMG="dist/QuickRAW-${VERSION}-macos-${ARCH}.dmg"
STAGE="build/macos-dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "QuickRAW $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "--- built $DMG ($(du -h "$DMG" | cut -f1))"
