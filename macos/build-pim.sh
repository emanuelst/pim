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
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Pim' "$ROOT/build/Pim.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Pim' "$ROOT/build/Pim.app/Contents/Info.plist"
codesign --force --deep --sign - "$ROOT/build/Pim.app" >/dev/null
printf '%s\n' "$ROOT/build/Pim.app"
