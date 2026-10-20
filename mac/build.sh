#!/bin/bash
# Builds "GearVR Remote.app" with plain swiftc (Command Line Tools are enough; no Xcode project).
#
#   ./build.sh           build $BUILD/GearVR Remote.app (universal arm64 + x86_64)
#   ./build.sh test      run the core tests against recorded controller packets
#   ./build.sh install   build, then copy the app to /Applications and launch it
#   ./build.sh run       build, then launch from $BUILD/
#   ./build.sh dist      build, then package $BUILD/GearVR-Remote-<version>.dmg for distribution
#
# Release signing (all optional; without them the app is signed locally or ad hoc):
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"  hardened runtime + timestamp
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD               also notarize and staple the DMG
#   BUILD_NUMBER                                              CFBundleVersion (default: $VERSION)
set -euo pipefail
cd "$(dirname "$0")"

NAME="GearVR Remote"
EXE="GearVRRemote"
BUNDLE_ID="com.dennisonbertram.gearvr-remote"
VERSION="${VERSION:-1.8.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"
MIN_OS="14.0"
# Spotlight skips directories ending in .noindex, so the build output never shows up
# alongside the installed app when you search for it.
BUILD="build.noindex"
APP="$BUILD/$NAME.app"
FLAGS=(-swift-version 5 -O)

run_tests() {
    mkdir -p "$BUILD"
    swiftc "${FLAGS[@]}" Sources/Core/*.swift Tests/main.swift -o $BUILD/core-tests
    $BUILD/core-tests ../tests_fixtures.json
}

# macOS ties Accessibility permission to the code signature. Ad-hoc signatures change
# every build, which silently revokes the permission. If a local identity named
# "GearVR Remote Local Signing" exists (see README), sign with it so the grant sticks.
signing_identity() {
    if [ -n "${SIGN_IDENTITY:-}" ]; then echo "$SIGN_IDENTITY"; return; fi
    local id
    id=$(security find-identity -p codesigning 2>/dev/null | awk '/"GearVR Remote Local Signing"/ {print $2; exit}')
    echo "${id:--}"
}

# A Developer ID signature is stable across releases, so permissions survive updates,
# and with the hardened runtime and a timestamp it can be notarized.
is_developer_id() { [[ "$1" == "Developer ID Application:"* ]]; }

notarize() {
    local file="$1" out id
    if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${APPLE_APP_PASSWORD:-}" ]; then
        echo "not notarizing: set APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD"; return
    fi
    echo "notarizing $file (this takes a few minutes)..."
    # notarytool exits 0 even when Apple rejects the upload, so check the status itself.
    out=$(xcrun notarytool submit "$file" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" --wait --output-format json)
    if ! grep -q '"status" *: *"Accepted"' <<<"$out"; then
        echo "notarization failed: $out"
        id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' <<<"$out")
        [ -n "$id" ] && xcrun notarytool log "$id" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_PASSWORD"
        exit 1
    fi
    xcrun stapler staple "$file"
}

make_icon() {
    swiftc -O tools/make_icon.swift -o $BUILD/make_icon
    rm -rf $BUILD/AppIcon.iconset
    $BUILD/make_icon $BUILD/AppIcon.iconset
    iconutil -c icns $BUILD/AppIcon.iconset -o $BUILD/AppIcon.icns
}

build_app() {
    mkdir -p "$BUILD"
    for arch in arm64 x86_64; do
        echo "compiling ${arch}..."
        swiftc "${FLAGS[@]}" -parse-as-library -target "$arch-apple-macos$MIN_OS" \
            Sources/Core/*.swift Sources/App/*.swift -o "$BUILD/$EXE-$arch"
    done
    [ $BUILD/AppIcon.icns -nt tools/make_icon.swift ] || make_icon

    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    lipo -create "$BUILD/$EXE-arm64" "$BUILD/$EXE-x86_64" -output "$APP/Contents/MacOS/$EXE"
    cp $BUILD/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXE</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Dennison Bertram. MIT License.</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>GearVR Remote connects to your Samsung Gear VR Controller over Bluetooth.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>GearVR Remote runs the shell commands and scripts you assign to controller buttons.</string>
</dict>
</plist>
PLIST
    local id; id=$(signing_identity)
    if is_developer_id "$id"; then
        codesign --force --options runtime --timestamp --entitlements GearVRRemote.entitlements \
            --sign "$id" --identifier "$BUNDLE_ID" "$APP"
    else
        codesign --force --sign "$id" --identifier "$BUNDLE_ID" "$APP"
    fi
    echo "built $APP"
}

make_dmg() {
    local stage="$BUILD/dmg" dmg="$BUILD/GearVR-Remote-$VERSION.dmg"
    rm -rf "$stage" "$dmg"
    mkdir -p "$stage"
    cp -R "$APP" "$stage/"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "$NAME" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
    rm -rf "$stage"
    local id; id=$(signing_identity)
    if is_developer_id "$id"; then
        codesign --force --timestamp --sign "$id" "$dmg"
        notarize "$dmg"
    fi
    echo "packaged $dmg"
}

case "${1:-build}" in
    test) run_tests ;;
    build) build_app ;;
    run) build_app; open "$APP" ;;
    dist) build_app; make_dmg ;;
    install)
        build_app
        pkill -x "$EXE" 2>/dev/null || true
        rm -rf "/Applications/$NAME.app"
        cp -R "$APP" /Applications/
        open "/Applications/$NAME.app"
        echo "installed /Applications/$NAME.app"
        ;;
    *) echo "usage: $0 [build|test|run|install|dist]"; exit 1 ;;
esac
