#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/Pim.app"
[ -d "$APP" ] || "$ROOT/macos/build-pim.sh" >/dev/null
cd "$ROOT"
exec env ApplePersistenceIgnoreState=YES "$APP/Contents/MacOS/ghostty"
