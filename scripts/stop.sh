#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if [[ ! -f "$COMFYUI_PID_FILE" ]]; then
  printf '%s\n' 'ComfyUI is not running (no PID file).'
  exit 0
fi

pid="$(tr -d '[:space:]' < "$COMFYUI_PID_FILE")"
if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
  printf 'Removing invalid PID file: %s\n' "$COMFYUI_PID_FILE"
  rm -f "$COMFYUI_PID_FILE"
  exit 0
fi

if ! pid_is_running "$pid"; then
  printf 'Removing stale PID file: %s\n' "$COMFYUI_PID_FILE"
  rm -f "$COMFYUI_PID_FILE"
  exit 0
fi

if ! pid_matches_comfyui "$pid"; then
  die "PID file points to a different live process ($pid); refusing to stop it"
fi

printf 'Stopping ComfyUI PID %s...\n' "$pid"
kill "$pid"
for _ in {1..20}; do
  if ! pid_is_running "$pid"; then
    rm -f "$COMFYUI_PID_FILE"
    printf '%s\n' 'ComfyUI stopped.'
    exit 0
  fi
  sleep 1
done

if pid_matches_comfyui "$pid"; then
  printf 'ComfyUI did not stop after 20 seconds; sending SIGKILL.\n' >&2
  kill -KILL "$pid"
else
  die "PID $pid changed before forced stop; refusing to signal the replacement process"
fi
rm -f "$COMFYUI_PID_FILE"
printf '%s\n' 'ComfyUI stopped.'
