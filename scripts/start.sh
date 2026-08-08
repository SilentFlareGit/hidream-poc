#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

validate_port 'COMFYUI_PORT' "$COMFYUI_PORT"
validate_port 'SSH_TUNNEL_PORT' "$SSH_TUNNEL_PORT"
validate_port 'SSH_LOCAL_PORT' "$SSH_LOCAL_PORT"

case "$COMFYUI_HOST" in
  127.0.0.1|::1)
    ;;
  *)
    if [[ "$COMFYUI_ALLOW_NON_LOOPBACK" != '1' ]]; then
      die "COMFYUI_HOST=$COMFYUI_HOST is not loopback. Set COMFYUI_ALLOW_NON_LOOPBACK=1 only after reviewing the exposure and firewall implications."
    fi
    printf 'WARNING: ComfyUI will listen on non-loopback address %s. Verify Vast firewall/network rules; this can expose port %s publicly.\n' "$COMFYUI_HOST" "$COMFYUI_PORT" >&2
    ;;
esac

VENV_PYTHON="$COMFYUI_VENV_DIR/bin/python"
[[ -x "$VENV_PYTHON" ]] || die "ComfyUI Python environment is missing. Run: bash scripts/setup-comfyui.sh"
[[ -f "$COMFYUI_DIR/main.py" ]] || die "ComfyUI checkout is missing. Run: bash scripts/setup-comfyui.sh"

mkdir -p "$COMFYUI_RUNTIME_DIR" "$COMFYUI_LOG_DIR"
umask 077

if [[ -f "$COMFYUI_PID_FILE" ]]; then
  existing_pid="$(tr -d '[:space:]' < "$COMFYUI_PID_FILE")"
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && pid_is_running "$existing_pid"; then
    if pid_matches_comfyui "$existing_pid"; then
      die "ComfyUI is already running with PID $existing_pid"
    fi
    die "PID file $COMFYUI_PID_FILE points to a different live process ($existing_pid); refusing to overwrite it"
  fi
  printf 'Removing stale PID file: %s\n' "$COMFYUI_PID_FILE"
  rm -f "$COMFYUI_PID_FILE"
fi

if port_in_use "$COMFYUI_PORT"; then
  die "TCP port $COMFYUI_PORT is already in use. Stop its owner or choose another COMFYUI_PORT."
else
  port_status=$?
  [[ "$port_status" -eq 1 ]] || die "Could not verify that TCP port $COMFYUI_PORT is free; install ss or lsof and retry."
fi

if [[ -d "$COMFYUI_DIR/.git" || -f "$COMFYUI_DIR/.git" ]]; then
  running_commit="$(git -C "$COMFYUI_DIR" rev-parse HEAD 2>/dev/null || true)"
else
  running_commit='unknown'
fi

printf '\n[%s] Starting ComfyUI\n' "$(date -Is)" >> "$COMFYUI_LOG_FILE"
printf 'Commit: %s\n' "$running_commit" >> "$COMFYUI_LOG_FILE"
printf 'Listen: %s:%s\n' "$COMFYUI_HOST" "$COMFYUI_PORT" >> "$COMFYUI_LOG_FILE"

(
  cd "$COMFYUI_DIR"
  exec nohup "$VENV_PYTHON" -u "$COMFYUI_DIR/main.py" --listen "$COMFYUI_HOST" --port "$COMFYUI_PORT"
) >> "$COMFYUI_LOG_FILE" 2>&1 < /dev/null &
comfyui_pid=$!
printf '%s\n' "$comfyui_pid" > "$COMFYUI_PID_FILE"

sleep 1
if ! pid_is_running "$comfyui_pid"; then
  printf 'ComfyUI exited during startup. Recent log output:\n' >&2
  tail -n 40 "$COMFYUI_LOG_FILE" >&2 || true
  rm -f "$COMFYUI_PID_FILE"
  exit 1
fi

printf 'ComfyUI started with PID %s\n' "$comfyui_pid"
printf 'Log file: %s\n' "$COMFYUI_LOG_FILE"
printf 'PID file: %s\n' "$COMFYUI_PID_FILE"
printf '%s\n' 'Run this SSH tunnel from your local computer:'
printf 'ssh -N -L %s:127.0.0.1:%s -p %s %s@%s\n' "$SSH_LOCAL_PORT" "$COMFYUI_PORT" "$SSH_TUNNEL_PORT" "$SSH_TUNNEL_USER" "$SSH_TUNNEL_HOST"
printf 'Then open: http://127.0.0.1:%s\n' "$SSH_LOCAL_PORT"
