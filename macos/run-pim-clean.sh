#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
AGENT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pim-screenshot-agent.XXXXXX")
WORKSPACE_DIR="$AGENT_DIR/Pim Demo"

cleanup() {
  rm -rf "$AGENT_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$AGENT_DIR/sessions" "$WORKSPACE_DIR"
cat > "$AGENT_DIR/models.json" <<'JSON'
{
  "providers": {
    "pim-demo": {
      "baseUrl": "http://127.0.0.1:9/v1",
      "api": "openai-completions",
      "apiKey": "pim-screenshot-only",
      "models": [
        {
          "id": "pim-demo-model",
          "name": "Pim Demo Model",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 128000,
          "maxTokens": 4096,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
JSON
export PIM_AGENT_DIR="$AGENT_DIR"
export PI_CODING_AGENT_DIR="$AGENT_DIR"
export PIM_WORKSPACE_DIR="$WORKSPACE_DIR"

printf 'Pim clean screenshot environment: %s\n' "$AGENT_DIR"
"$ROOT/macos/run-pim.sh" >/dev/null 2>&1
