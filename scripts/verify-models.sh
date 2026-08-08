#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if ! PYTHON_BIN="$(resolve_python_executable "$COMFYUI_PYTHON")"; then
  die "COMFYUI_PYTHON could not be resolved: $COMFYUI_PYTHON"
fi

exec "$PYTHON_BIN" "$SCRIPT_DIR/download-models.py" \
  --manifest "$POC_ROOT/config/models.json" \
  --comfyui-dir "$COMFYUI_DIR" \
  --verify-only \
  "$@"
