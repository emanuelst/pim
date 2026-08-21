#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
AGENT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pim-screenshot-agent.XXXXXX")

cleanup() {
  rm -rf "$AGENT_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$AGENT_DIR/sessions"
export PIM_AGENT_DIR="$AGENT_DIR"
export PI_CODING_AGENT_DIR="$AGENT_DIR"

printf 'Pim clean screenshot environment: %s\n' "$AGENT_DIR"
"$ROOT/macos/run-pim.sh" >/dev/null 2>&1
