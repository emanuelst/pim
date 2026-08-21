#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GHOSTTY="$ROOT/vendor/ghostty"
PATCH="$ROOT/macos-ghostty.patch"
COMMIT=fa7fe3b3afd04f11281358ee3704f40b628f6e35

if [ ! -d "$GHOSTTY/.git" ]; then
  mkdir -p "$ROOT/vendor"
  git clone --filter=blob:none https://github.com/ghostty-org/ghostty.git "$GHOSTTY"
fi

cd "$GHOSTTY"
if [ "$(git rev-parse HEAD)" != "$COMMIT" ]; then
  git fetch --depth 1 origin "$COMMIT"
  git checkout --detach "$COMMIT"
fi
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
fi

zig build -Doptimize=Debug -Demit-macos-app=false
cd macos
xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -configuration Debug SYMROOT="$PWD/build" build >/dev/null

rm -rf "$ROOT/build"
ditto "$PWD/build/Debug/Ghostty.app" "$ROOT/build/Pim.app"
cp "$ROOT/macos/pim-bridge.ts" "$ROOT/build/Pim.app/Contents/Resources/pim-bridge.ts"

# Replace Ghostty's inherited icon with Pim's native app icon.
ICONSET="$ROOT/build/Pim.iconset"
mkdir -p "$ICONSET"
for spec in \
  "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
  "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
  "512 512x512" "1024 512x512@2x"; do
  size=${spec%% *}
  name=${spec#* }
  sips -z "$size" "$size" "$ROOT/macos/assets/PimIcon.png" \
    --out "$ICONSET/icon_${name}.png" >/dev/null
 done
iconutil -c icns "$ICONSET" -o "$ROOT/build/Pim.icns"
cp "$ROOT/build/Pim.icns" "$ROOT/build/Pim.app/Contents/Resources/Pim.icns"
rm -rf "$ICONSET" "$ROOT/build/Pim.icns"

/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Pim' "$ROOT/build/Pim.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Pim' "$ROOT/build/Pim.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.emanuelstadler.pim' "$ROOT/build/Pim.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile Pim' "$ROOT/build/Pim.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconName Pim' "$ROOT/build/Pim.app/Contents/Info.plist"
codesign --force --deep --sign - "$ROOT/build/Pim.app" >/dev/null
printf '%s\n' "$ROOT/build/Pim.app"
