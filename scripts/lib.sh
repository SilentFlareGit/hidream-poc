#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POC_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$POC_ROOT/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

OFFICIAL_COMFYUI_REPO="https://github.com/Comfy-Org/ComfyUI.git"
COMFYUI_REPO="${COMFYUI_REPO:-$OFFICIAL_COMFYUI_REPO}"
COMFYUI_COMMIT="${COMFYUI_COMMIT:-}"
COMFYUI_HOST="${COMFYUI_HOST:-127.0.0.1}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
COMFYUI_ALLOW_NON_LOOPBACK="${COMFYUI_ALLOW_NON_LOOPBACK:-0}"
COMFYUI_PYTHON="${COMFYUI_PYTHON:-python3}"
COMFYUI_RUNTIME_DIR="${COMFYUI_RUNTIME_DIR:-.runtime}"
COMFYUI_DIR="${COMFYUI_DIR:-$COMFYUI_RUNTIME_DIR/comfyui}"
COMFYUI_VENV_DIR="${COMFYUI_VENV_DIR:-$COMFYUI_RUNTIME_DIR/venv}"
COMFYUI_LOG_DIR="${COMFYUI_LOG_DIR:-$COMFYUI_RUNTIME_DIR/logs}"
COMFYUI_PID_FILE="${COMFYUI_PID_FILE:-$COMFYUI_RUNTIME_DIR/comfyui.pid}"
COMFYUI_LOG_FILE="${COMFYUI_LOG_FILE:-$COMFYUI_LOG_DIR/comfyui.log}"
SSH_TUNNEL_HOST="${SSH_TUNNEL_HOST:-YOUR_VAST_SSH_HOST}"
SSH_TUNNEL_PORT="${SSH_TUNNEL_PORT:-22}"
SSH_TUNNEL_USER="${SSH_TUNNEL_USER:-root}"
SSH_LOCAL_PORT="${SSH_LOCAL_PORT:-$COMFYUI_PORT}"

resolve_path() {
  local value="$1"
  if [[ "$value" == /* ]]; then
    printf '%s\n' "$value"
  else
    printf '%s/%s\n' "$POC_ROOT" "${value#./}"
  fi
}

COMFYUI_RUNTIME_DIR="$(resolve_path "$COMFYUI_RUNTIME_DIR")"
COMFYUI_DIR="$(resolve_path "$COMFYUI_DIR")"
COMFYUI_VENV_DIR="$(resolve_path "$COMFYUI_VENV_DIR")"
COMFYUI_LOG_DIR="$(resolve_path "$COMFYUI_LOG_DIR")"
COMFYUI_PID_FILE="$(resolve_path "$COMFYUI_PID_FILE")"
COMFYUI_LOG_FILE="$(resolve_path "$COMFYUI_LOG_FILE")"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

validate_port() {
  local label="$1"
  local value="$2"
  local number

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    die "$label must be a number from 1 to 65535; got '$value'"
  fi
  number=$((10#$value))
  if (( number < 1 || number > 65535 )); then
    die "$label must be a number from 1 to 65535; got '$value'"
  fi
}

# Return 0 when a listening TCP socket owns the port, 1 when it is free,
# and 2 when no local socket inspection tool is available.
port_in_use() {
  local port="$1"
  local socket_listing
  local hex_port
  local proc_files=()

  if command -v ss >/dev/null 2>&1; then
    if ! socket_listing="$(ss -H -ltn 2>/dev/null)"; then
      return 2
    fi
    awk -v port="$port" '$4 ~ (":" port "$") { found = 1 } END { exit !found }' <<<"$socket_listing"
    return $?
  fi

  if command -v lsof >/dev/null 2>&1; then
    socket_listing="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)"
    [[ -n "$socket_listing" ]]
    return $?
  fi

  [[ -r /proc/net/tcp ]] && proc_files+=(/proc/net/tcp)
  [[ -r /proc/net/tcp6 ]] && proc_files+=(/proc/net/tcp6)
  if (( ${#proc_files[@]} > 0 )); then
    printf -v hex_port '%04X' "$((10#$port))"
    awk -v port="$hex_port" '$2 ~ (":" port "$") && $4 == "0A" { found = 1 } END { exit !found }' "${proc_files[@]}" 2>/dev/null
    return $?
  fi

  return 2
}

pid_is_running() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null
}

process_args() {
  local pid="$1"
  ps -p "$pid" -o args= 2>/dev/null || true
}

pid_matches_comfyui() {
  local pid="$1"
  local args
  args="$(process_args "$pid")"
  [[ "$args" == *"$COMFYUI_DIR/main.py"* ]]
}
