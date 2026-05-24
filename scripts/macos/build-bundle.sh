#!/usr/bin/env bash
#
# Build, sign, and notarize a self-contained ImPPG.app + DMG for macOS.
#
# Always produces a Developer ID signed, Apple notarized, and stapled
# distribution artifact. Notarization adds ~5-15 min per submission (.app and
# DMG are notarized separately), so a full run is typically 20-30 min.
#
# Required Homebrew packages:
#   boost cfitsio cmake freeimage glew mesa pkg-config wxwidgets lua dylibbundler
#
# Required setup (one time):
#   1. "Developer ID Application: ... (<TEAM_ID>)" cert installed in keychain.
#   2. notarytool credentials stored under the profile name below:
#        xcrun notarytool store-credentials "<profile>" \
#            --apple-id <your-apple-id> --team-id <your-team-id>
#
# Overridable via environment:
#   IMPPG_SIGN_IDENTITY   (default: Developer ID Application: Core Ultrasound, LLC (6VK3JZ7LRU))
#   IMPPG_NOTARY_PROFILE  (default: imppg-notary)

set -euo pipefail

APP_NAME="ImPPG"
BUNDLE_ID="com.bensmith.imppg"
SIGN_IDENTITY="${IMPPG_SIGN_IDENTITY:-Developer ID Application: Core Ultrasound, LLC (6VK3JZ7LRU)}"
NOTARY_PROFILE="${IMPPG_NOTARY_PROFILE:-imppg-notary}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build-macos"
DIST_DIR="$REPO_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
PLIST_TEMPLATE="$SCRIPT_DIR/Info.plist.in"

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//; s/^set -.*//'
            exit 0
            ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# --- preflight ---
[[ "$(uname)" == "Darwin" ]] || { echo "must run on macOS" >&2; exit 1; }
for tool in cmake make sips iconutil hdiutil codesign dylibbundler ditto xcrun; do
    command -v "$tool" >/dev/null \
        || { echo "missing required tool: $tool" >&2; exit 1; }
done
if ! security find-identity -p codesigning -v | grep -qF "$SIGN_IDENTITY"; then
    echo "missing signing identity in keychain: $SIGN_IDENTITY" >&2
    echo "list available identities with: security find-identity -p codesigning -v" >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "notarytool keychain profile not found or invalid: $NOTARY_PROFILE" >&2
    echo "set up with:" >&2
    echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id <team>" >&2
    exit 1
fi

VERSION_MAJOR=$(awk '/^set\(IMPPG_VERSION_MAJOR /    {gsub(/[^0-9]/,"",$2); print $2}' "$REPO_ROOT/CMakeLists.txt")
VERSION_MINOR=$(awk '/^set\(IMPPG_VERSION_MINOR /    {gsub(/[^0-9]/,"",$2); print $2}' "$REPO_ROOT/CMakeLists.txt")
VERSION_PATCH=$(awk '/^set\(IMPPG_VERSION_SUBMINOR / {gsub(/[^0-9]/,"",$2); print $2}' "$REPO_ROOT/CMakeLists.txt")
VERSION="${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}"
echo "==> Building ImPPG $VERSION ($BUNDLE_ID)"
echo "    sign-as:    $SIGN_IDENTITY"
echo "    notarize:   profile $NOTARY_PROFILE"

mkdir -p "$BUILD_DIR" "$DIST_DIR"

# --- compile ---
echo "==> Configuring CMake"
( cd "$BUILD_DIR" && cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release "$REPO_ROOT" )
echo "==> Compiling"
make -C "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"
[[ -x "$BUILD_DIR/imppg" ]] || { echo "build did not produce $BUILD_DIR/imppg" >&2; exit 1; }

# --- icon ---
echo "==> Generating .icns"
ICONSET_DIR="$BUILD_DIR/imppg.iconset"
SRC_ICON="$REPO_ROOT/images/imppg-app.png"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
# Source PNG is 256x256, so 256 is the largest size we can render without
# upscaling. That covers icon_256x256 (= 128x128@2x). Skip 512+ entries.
for spec in \
    "16:icon_16x16" \
    "32:icon_16x16@2x" \
    "32:icon_32x32" \
    "64:icon_32x32@2x" \
    "128:icon_128x128" \
    "256:icon_128x128@2x" \
    "256:icon_256x256"
do
    sz="${spec%%:*}"
    name="${spec##*:}"
    sips -z "$sz" "$sz" "$SRC_ICON" --out "$ICONSET_DIR/${name}.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$BUILD_DIR/imppg.icns"

# --- assemble bundle ---
echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp "$BUILD_DIR/imppg"      "$APP_BUNDLE/Contents/MacOS/imppg"
cp "$BUILD_DIR/imppg.icns" "$APP_BUNDLE/Contents/Resources/imppg.icns"
cp -R "$REPO_ROOT/images"  "$APP_BUNDLE/Contents/Resources/images"
cp -R "$REPO_ROOT/shaders" "$APP_BUNDLE/Contents/Resources/shaders"
cp -R "$REPO_ROOT/lang"    "$APP_BUNDLE/Contents/Resources/lang"
sed -e "s/@VERSION@/${VERSION}/g" \
    -e "s/@BUNDLE_ID@/${BUNDLE_ID}/g" \
    "$PLIST_TEMPLATE" > "$APP_BUNDLE/Contents/Info.plist"

# --- bundle dylibs ---
echo "==> Bundling Homebrew dylibs"
dylibbundler \
    --fix-file "$APP_BUNDLE/Contents/MacOS/imppg" \
    --bundle-deps \
    --dest-dir "$APP_BUNDLE/Contents/Frameworks/" \
    --install-path "@executable_path/../Frameworks/" \
    --overwrite-dir \
    --no-codesign

if otool -L "$APP_BUNDLE/Contents/MacOS/imppg" | grep -q '/opt/homebrew\|/usr/local/Cellar'; then
    echo "ERROR: Homebrew paths still present in binary after dylibbundler:" >&2
    otool -L "$APP_BUNDLE/Contents/MacOS/imppg" | grep '/opt/homebrew\|/usr/local/Cellar' >&2
    exit 1
fi

# --- sign every Mach-O in the bundle (deepest first) ---
echo "==> Signing (Developer ID, hardened runtime)"
CODESIGN_FLAGS=(--force --timestamp --options runtime --sign "$SIGN_IDENTITY")
while IFS= read -r -d '' f; do
    codesign "${CODESIGN_FLAGS[@]}" "$f"
done < <(find "$APP_BUNDLE/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)
codesign "${CODESIGN_FLAGS[@]}" "$APP_BUNDLE/Contents/MacOS/imppg"
codesign "${CODESIGN_FLAGS[@]}" "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

# Helper: submit an artifact to notarytool, wait, and dump the rejection log
# on failure. $1 = path to artifact, $2 = human label for messages.
notarize_or_die() {
    local artifact="$1"
    local label="$2"
    local out sid
    if ! out=$(xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1); then
        echo "$out" >&2
        sid=$(echo "$out" | awk '/^  id: / {print $2; exit}')
        [[ -n "$sid" ]] && {
            echo "--- notarytool log for $label submission $sid ---" >&2
            xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        }
        exit 1
    fi
    echo "$out"
    if ! echo "$out" | grep -qE "status: *Accepted"; then
        sid=$(echo "$out" | awk '/^  id: / {print $2; exit}')
        echo "$label notarization did not return Accepted." >&2
        [[ -n "$sid" ]] && xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" >&2
        exit 1
    fi
}

# --- notarize the .app, then staple ---
echo "==> Notarizing .app (5-15 min)"
APP_ZIP="$BUILD_DIR/${APP_NAME}.app.zip"
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
notarize_or_die "$APP_ZIP" ".app"
echo "==> Stapling ticket to .app"
xcrun stapler staple "$APP_BUNDLE"

# --- create DMG from the stapled .app ---
echo "==> Creating DMG"
DMG="$DIST_DIR/${APP_NAME}-${VERSION}-macOS.dmg"
DMG_STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$DMG_STAGE" "$DMG"
mkdir -p "$DMG_STAGE"
cp -R "$APP_BUNDLE" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

# --- notarize the DMG, then staple ---
echo "==> Notarizing DMG (5-15 min)"
notarize_or_die "$DMG" "DMG"
echo "==> Stapling ticket to DMG"
xcrun stapler staple "$DMG"

# --- verify Gatekeeper acceptance ---
echo "==> Gatekeeper check"
echo "    .app:"
spctl --assess --type execute --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/      /'
echo "    DMG:"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | sed 's/^/      /'

echo
echo "    Bundle: $APP_BUNDLE ($(du -sh "$APP_BUNDLE" | cut -f1))"
echo "    DMG:    $DMG ($(du -h "$DMG" | cut -f1))"
echo "Done. Both .app and DMG are signed, notarized, and stapled."
