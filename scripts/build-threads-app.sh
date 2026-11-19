#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/sidepad-threads-clang-cache}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${TMPDIR:-/tmp}/sidepad-threads-cache}"
swift build --disable-sandbox
binary_path=$(swift build --disable-sandbox --show-bin-path)
app_name="SidePad Threads"
if [ "${1:-}" = "--demo" ] || [ "${1:-}" = "--demo-preview" ]; then app_name="SidePad Threads Demo"; fi
if [ "${1:-}" = "--demo-v2" ]; then app_name="SidePad Threads V2 Demo"; fi
app_path="$PWD/.build/$app_name.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path/SidePad" "$app_path/Contents/MacOS/SidePad"
cp Info.plist "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $app_name" "$app_path/Contents/Info.plist"
if [ "${1:-}" = "--demo" ] || [ "${1:-}" = "--demo-preview" ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.SidePad.ThreadsDemo' "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :SidePadDemo bool true' "$app_path/Contents/Info.plist"
fi
if [ "${1:-}" = "--demo-preview" ]; then
    /usr/libexec/PlistBuddy -c 'Add :SidePadDemoPreview bool true' "$app_path/Contents/Info.plist"
fi
if [ "${1:-}" = "--demo-v2" ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.SidePad.ThreadsV2Demo' "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :SidePadDemo bool true' "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :SidePadDemoV2 bool true' "$app_path/Contents/Info.plist"
fi
# AIResources resolves this packaged bundle before falling back to SwiftPM's development path.
ditto "$binary_path/SidePad_SidePad.bundle" "$app_path/Contents/Resources/SidePad_SidePad.bundle"
codesign --force --sign - "$app_path"
codesign --verify --strict "$app_path"
printf '%s\n' "$app_path"
