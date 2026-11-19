#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Prefer the complete toolchain; CLT can expose Testing without its Foundation overlay.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
# CLT ships Testing but this SwiftPM version does not discover its framework path.
if [ -d "$developer_dir/Library/Developer/Frameworks/Testing.framework" ]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    exec swift test --disable-sandbox --disable-xctest --enable-swift-testing \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xlinker "-F$frameworks" -Xlinker -rpath -Xlinker "$frameworks"
fi
exec swift test --disable-sandbox --disable-xctest --enable-swift-testing
