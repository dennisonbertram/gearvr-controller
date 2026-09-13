#!/bin/bash
# Builds "GearVR Remote.app" with plain swiftc (Command Line Tools are enough; no Xcode project).
#
#   ./build.sh           build build/GearVR Remote.app (universal arm64 + x86_64)
#   ./build.sh test      run the core tests against recorded controller packets
#   ./build.sh install   build, then copy the app to /Applications and launch it
#   ./build.sh run       build, then launch from build/
#   ./build.sh dist      build, then package build/GearVR-Remote-<version>.dmg for distribution
set -euo pipefail
cd "$(dirname "$0")"

NAME="GearVR Remote"
EXE="GearVRRemote"
BUNDLE_ID="com.dennisonbertram.gearvr-remote"
VERSION="${VERSION:-1.6.0}"
MIN_OS="14.0"
APP="build/$NAME.app"
FLAGS=(-swift-version 5 -O)

run_tests() {
    mkdir -p build
    swiftc "${FLAGS[@]}" Sources/Core/*.swift Tests/main.swift -o build/core-tests
    build/core-tests ../tests_fixtures.json
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

make_icon() {
    swiftc -O tools/make_icon.swift -o build/make_icon
    rm -rf build/AppIcon.iconset
    build/make_icon build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
}

build_app() {
    mkdir -p build
    for arch in arm64 x86_64; do
        echo "compiling ${arch}..."
        swiftc "${FLAGS[@]}" -parse-as-library -target "$arch-apple-macos$MIN_OS" \
            Sources/Core/*.swift Sources/App/*.swift -o "build/$EXE-$arch"
    done
    [ build/AppIcon.icns -nt tools/make_icon.swift ] || make_icon

    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    lipo -create "build/$EXE-arm64" "build/$EXE-x86_64" -output "$APP/Contents/MacOS/$EXE"
    cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>GearVR Remote connects to your Samsung Gear VR Controller over Bluetooth.</string>
</dict>
</plist>
PLIST
    codesign --force --sign "$(signing_identity)" --identifier "$BUNDLE_ID" "$APP"
    echo "built $APP"
}

make_dmg() {
    local stage="build/dmg" dmg="build/GearVR-Remote-$VERSION.dmg"
    rm -rf "$stage" "$dmg"
    mkdir -p "$stage"
    cp -R "$APP" "$stage/"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "$NAME" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
    rm -rf "$stage"
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
