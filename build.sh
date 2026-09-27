#!/bin/zsh
# Build Media Monitor.app into outputs/. With --install, also replace /Applications/Media Monitor.app and relaunch it.
set -euo pipefail
ROOT="${0:A:h}"
NAME="Media Monitor"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Resources/Info.plist")
STAGE="$ROOT/work/stage/$NAME.app"
APP="$ROOT/outputs/$NAME.app"

# Build into a staging bundle so a failed build never destroys the last good one.
rm -rf "$ROOT/work/stage"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$ROOT/outputs"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.2 \
  -framework AppKit -framework SwiftUI -framework IOKit -framework ApplicationServices -framework CoreAudio \
  -o "$STAGE/Contents/MacOS/MediaMonitor" "$ROOT"/Sources/*.swift
clang -O2 -fobjc-arc -Wall -dynamiclib -mmacosx-version-min=14.2 -framework Foundation \
  -o "$STAGE/Contents/Resources/libNowPlayingHelper.dylib" "$ROOT/Helper/NowPlayingHelper.m"

clang -O2 -fobjc-arc -framework Cocoa -o "$ROOT/work/make-icon" "$ROOT/Tools/MakeIcon.m"
"$ROOT/work/make-icon" "$ROOT/work/AppIcon.png"
[[ -s "$ROOT/work/AppIcon.png" ]] || { print -u2 "icon generation failed"; exit 1; }
clang -O2 -fobjc-arc -framework Foundation -o "$ROOT/work/make-icns" "$ROOT/Tools/MakeIcns.m"
"$ROOT/work/make-icns" "$ROOT/work/AppIcon.png" "$STAGE/Contents/Resources/AppIcon.icns"
[[ -s "$STAGE/Contents/Resources/AppIcon.icns" ]] || { print -u2 "icns generation failed"; exit 1; }

cp "$ROOT/Resources/Info.plist" "$STAGE/Contents/Info.plist"
ditto "$ROOT/ChromeExtension" "$STAGE/Contents/Resources/ChromeExtension"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
# A stable local identity keeps the Accessibility grant across rebuilds; ad-hoc signing changes it every build.
SIGN_ID=-
security find-identity -p codesigning | grep -q "Media Monitor Local Signing" && SIGN_ID="Media Monitor Local Signing"
codesign --force --sign "$SIGN_ID" --timestamp=none "$STAGE/Contents/Resources/libNowPlayingHelper.dylib"
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" --timestamp=none "$STAGE"
codesign --verify --verbose=1 "$STAGE"

rm -rf "$APP"
mv "$STAGE" "$APP"
echo "$APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/$NAME.app"
  ditto "$APP" "$DEST.new"
  pkill -x MediaMonitor || true
  for _ in {1..50}; do pgrep -x MediaMonitor >/dev/null || break; sleep 0.1; done
  rm -rf "$DEST"
  mv "$DEST.new" "$DEST"
  touch "$DEST"
  open "$DEST"
  echo "Installed to /Applications"
fi
