#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GHOSTTY="$ROOT/vendor/ghostty"

# Ghostty is tracked as a Git subtree. Keep the source tree present and build
# directly from it; upstream updates are pulled with `git subtree pull`.
if [ ! -f "$GHOSTTY/build.zig" ]; then
  printf '%s\n' "Missing tracked Ghostty subtree at $GHOSTTY" >&2
  exit 1
fi

cd "$GHOSTTY"
zig build -Doptimize=ReleaseFast -Demit-macos-app=false
cd macos
xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -configuration ReleaseLocal SYMROOT="$PWD/build" build >/dev/null

rm -rf "$ROOT/build"
ditto "$PWD/build/ReleaseLocal/Ghostty.app" "$ROOT/build/Pim.app"
cp "$ROOT/macos/pim-bridge.ts" "$ROOT/build/Pim.app/Contents/Resources/pim-bridge.ts"

# Preserve the third-party license required by Ghostty's MIT license.
LICENSE_DIR="$ROOT/build/Pim.app/Contents/Resources/Third-Party-Licenses"
mkdir -p "$LICENSE_DIR"
cp "$GHOSTTY/LICENSE" "$LICENSE_DIR/Ghostty-LICENSE.txt"

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
# Pim owns its Dock identity. Remove Ghostty's plugin and fallback icon so
# LaunchServices cannot restore the inherited Ghostty icon after Pim exits.
rm -rf "$ROOT/build/Pim.app/Contents/PlugIns/DockTilePlugin.plugin"
rm -f "$ROOT/build/Pim.app/Contents/Resources/Ghostty.icns"
/usr/libexec/PlistBuddy -c 'Delete :NSDockTilePlugIn' "$ROOT/build/Pim.app/Contents/Info.plist"
# Give the copied app its own executable identity as well. This prevents the
# Dock from falling back to Ghostty's icon when the Pim process exits.
mv "$ROOT/build/Pim.app/Contents/MacOS/ghostty" "$ROOT/build/Pim.app/Contents/MacOS/Pim"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Pim' "$ROOT/build/Pim.app/Contents/Info.plist"
codesign --force --deep --sign - "$ROOT/build/Pim.app" >/dev/null
# Refresh LaunchServices so the Dock picks up Pim.icns immediately, including
# when the app is no longer running.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -u "$ROOT/build/Pim.app" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$ROOT/build/Pim.app" >/dev/null 2>&1 || true
fi
printf '%s\n' "$ROOT/build/Pim.app"
