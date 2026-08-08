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

if ! PYTHON_BIN="$(resolve_python_executable "$COMFYUI_PYTHON")"; then
  die "COMFYUI_PYTHON could not be resolved: $COMFYUI_PYTHON"
fi
if [[ ! -f "$COMFYUI_PYTHON_STATE_FILE" ]]; then
  die 'No validated COMFYUI_PYTHON state exists. Run bash scripts/setup-comfyui.sh first.'
fi
validated_python="$(sed -n '1p' "$COMFYUI_PYTHON_STATE_FILE")"
[[ "$validated_python" == "$PYTHON_BIN" ]] || die "COMFYUI_PYTHON changed since setup. Setup validated $validated_python, but the current selection is $PYTHON_BIN."
printf 'Python executable (%s): %s\n' "$COMFYUI_PYTHON_SOURCE" "$PYTHON_BIN"

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
printf 'Python: %s\n' "$PYTHON_BIN" >> "$COMFYUI_LOG_FILE"
printf 'Listen: %s:%s\n' "$COMFYUI_HOST" "$COMFYUI_PORT" >> "$COMFYUI_LOG_FILE"

(
  cd "$COMFYUI_DIR"
  exec nohup "$PYTHON_BIN" -u "$COMFYUI_DIR/main.py" --listen "$COMFYUI_HOST" --port "$COMFYUI_PORT"
) >> "$COMFYUI_LOG_FILE" 2>&1 < /dev/null &
comfyui_pid=$!
printf '%s\n' "$comfyui_pid" > "$COMFYUI_PID_FILE"

cleanup_failed_start() {
  local pid="$1"
  if pid_is_running "$pid" && pid_matches_comfyui "$pid"; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$COMFYUI_PID_FILE"
}

startup_failure() {
  local message="$1"
  printf 'ERROR: %s\n' "$message" >&2
  cleanup_failed_start "$comfyui_pid"
  printf 'Last 60 ComfyUI log lines:\n' >&2
  tail -n 60 "$COMFYUI_LOG_FILE" >&2 || true
  exit 1
}

comfyui_http_check() {
  local endpoint_host="$COMFYUI_HOST"
  local http_code

  command -v curl >/dev/null 2>&1 || return 2
  [[ "$endpoint_host" == '::1' ]] && endpoint_host='[::1]'
  [[ "$endpoint_host" == '0.0.0.0' ]] && endpoint_host='127.0.0.1'
  http_code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --connect-timeout 1 --max-time 2 "http://${endpoint_host}:${COMFYUI_PORT}/system_stats" 2>/dev/null || true)"
  case "$http_code" in
    2??) return 0 ;;
    404) return 2 ;;
    *) return 1 ;;
  esac
}

ready=0
http_readiness='not checked'
for _ in {1..60}; do
  pid_is_running "$comfyui_pid" || startup_failure "ComfyUI exited during startup."
  pid_matches_comfyui "$comfyui_pid" || startup_failure 'The ComfyUI PID no longer matches this repository checkout.'

  if port_in_use "$COMFYUI_PORT"; then
    if comfyui_http_check; then
      ready=1
      http_readiness='ok'
      break
    else
      http_status=$?
      if [[ "$http_status" -eq 2 ]]; then
        ready=1
        http_readiness='unavailable; port check passed'
        break
      fi
      http_readiness='waiting for /system_stats'
    fi
  else
    port_status=$?
    [[ "$port_status" -eq 2 ]] && startup_failure 'Cannot inspect the ComfyUI listening port during readiness verification.'
  fi
  sleep 1
done

[[ "$ready" -eq 1 ]] || startup_failure 'ComfyUI did not become ready within 60 seconds.'

printf 'ComfyUI started with PID %s\n' "$comfyui_pid"
printf 'Log file: %s\n' "$COMFYUI_LOG_FILE"
printf 'PID file: %s\n' "$COMFYUI_PID_FILE"
printf 'Readiness: TCP port %s is listening; HTTP /system_stats: %s\n' "$COMFYUI_PORT" "$http_readiness"
printf '%s\n' 'Run this SSH tunnel from your local computer:'
printf 'ssh -N -L %s:127.0.0.1:%s -p %s %s@%s\n' "$SSH_LOCAL_PORT" "$COMFYUI_PORT" "$SSH_TUNNEL_PORT" "$SSH_TUNNEL_USER" "$SSH_TUNNEL_HOST"
printf 'Then open: http://127.0.0.1:%s\n' "$SSH_LOCAL_PORT"
