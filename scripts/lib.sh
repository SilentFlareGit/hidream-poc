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
BLACKWELL_MIN_CUDA="12.8"
BLACKWELL_MIN_TORCH="2.7"

COMFYUI_REPO="${COMFYUI_REPO:-$OFFICIAL_COMFYUI_REPO}"
COMFYUI_COMMIT="${COMFYUI_COMMIT:-}"
COMFYUI_HOST="${COMFYUI_HOST:-127.0.0.1}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
COMFYUI_ALLOW_NON_LOOPBACK="${COMFYUI_ALLOW_NON_LOOPBACK:-0}"
COMFYUI_RUNTIME_DIR="${COMFYUI_RUNTIME_DIR:-.runtime}"
COMFYUI_DIR="${COMFYUI_DIR:-$COMFYUI_RUNTIME_DIR/comfyui}"
COMFYUI_LOG_DIR="${COMFYUI_LOG_DIR:-$COMFYUI_RUNTIME_DIR/logs}"
COMFYUI_PID_FILE="${COMFYUI_PID_FILE:-$COMFYUI_RUNTIME_DIR/comfyui.pid}"
COMFYUI_LOG_FILE="${COMFYUI_LOG_FILE:-$COMFYUI_LOG_DIR/comfyui.log}"
SSH_TUNNEL_HOST="${SSH_TUNNEL_HOST:-YOUR_VAST_SSH_HOST}"
SSH_TUNNEL_PORT="${SSH_TUNNEL_PORT:-22}"
SSH_TUNNEL_USER="${SSH_TUNNEL_USER:-root}"
SSH_LOCAL_PORT="${SSH_LOCAL_PORT:-$COMFYUI_PORT}"

COMFYUI_PYTHON_OVERRIDE="${COMFYUI_PYTHON:-}"
if [[ -n "$COMFYUI_PYTHON_OVERRIDE" ]]; then
  COMFYUI_PYTHON="$COMFYUI_PYTHON_OVERRIDE"
  COMFYUI_PYTHON_SOURCE='explicit COMFYUI_PYTHON'
elif [[ -x /venv/main/bin/python ]]; then
  COMFYUI_PYTHON='/venv/main/bin/python'
  COMFYUI_PYTHON_SOURCE='automatic /venv/main/bin/python'
else
  COMFYUI_PYTHON='python3'
  COMFYUI_PYTHON_SOURCE='automatic python3 fallback'
fi

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
COMFYUI_LOG_DIR="$(resolve_path "$COMFYUI_LOG_DIR")"
COMFYUI_PID_FILE="$(resolve_path "$COMFYUI_PID_FILE")"
COMFYUI_LOG_FILE="$(resolve_path "$COMFYUI_LOG_FILE")"
COMFYUI_PYTHON_STATE_FILE="$COMFYUI_RUNTIME_DIR/comfyui-python"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

resolve_python_executable() {
  local configured="$1"
  if [[ "$configured" == */* ]]; then
    [[ -x "$configured" ]] || return 1
    printf '%s\n' "$configured"
  else
    command -v "$configured"
  fi
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

version_at_least() {
  local actual="$1"
  local required="$2"
  awk -v actual="$actual" -v required="$required" '
    function valid(value) { return value ~ /^[0-9]+(\.[0-9]+)?/ }
    function major(value, parts) { split(value, parts, "."); return parts[1] + 0 }
    function minor(value, parts) { split(value, parts, "."); return (parts[2] == "" ? 0 : parts[2] + 0) }
    BEGIN {
      if (!valid(actual) || !valid(required)) exit 1
      if (major(actual) > major(required)) exit 0
      if (major(actual) < major(required)) exit 1
      if (minor(actual) >= minor(required)) exit 0
      exit 1
    }
  '
}

is_blackwell_gpu_name() {
  local name
  name="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  [[ "$name" == *'RTX 50'* || "$name" == *'BLACKWELL'* ]]
}

report_value() {
  local key="$1"
  local report="$2"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' <<<"$report"
}

# Print a stable diagnostic report and return non-zero when the selected
# interpreter cannot provide a working CUDA PyTorch runtime.
torch_probe() {
  local python_executable="$1"
  BLACKWELL_MIN_CUDA="$BLACKWELL_MIN_CUDA" BLACKWELL_MIN_TORCH="$BLACKWELL_MIN_TORCH" "$python_executable" - <<'PY'
import os
import platform
import re
import sys


def emit(key, value):
    text = str(value).replace("\n", "\\n")
    print(f"{key}={text}")


def version_at_least(actual, required):
    actual_match = re.match(r"^(\d+)(?:\.(\d+))?", str(actual))
    required_match = re.match(r"^(\d+)(?:\.(\d+))?", str(required))
    if not actual_match or not required_match:
        return False
    actual_value = (int(actual_match.group(1)), int(actual_match.group(2) or 0))
    required_value = (int(required_match.group(1)), int(required_match.group(2) or 0))
    return actual_value >= required_value


emit("python_executable", sys.executable)
emit("python_version", platform.python_version())

try:
    import torch
except BaseException as exc:
    emit("torch_import", f"error:{type(exc).__name__}:{exc}")
    emit("torch_version", "unavailable")
    emit("torch_cuda", "unavailable")
    emit("torch_file", "unavailable")
    emit("torchvision_version", "unavailable")
    emit("torchaudio_version", "unavailable")
    emit("probe_status", "failed")
    raise SystemExit(1)

torch_version = str(getattr(torch, "__version__", "unreported"))
torch_cuda = str(getattr(getattr(torch, "version", None), "cuda", None) or "unreported")
emit("torch_import", "ok")
emit("torch_version", torch_version)
emit("torch_cuda", torch_cuda)
emit("torch_file", getattr(torch, "__file__", "unreported"))

for module_name in ("torchvision", "torchaudio"):
    try:
        module = __import__(module_name)
        emit(f"{module_name}_version", getattr(module, "__version__", "unreported"))
    except BaseException:
        emit(f"{module_name}_version", "unavailable")

status = 0
try:
    cuda_available = bool(torch.cuda.is_available())
except BaseException as exc:
    cuda_available = False
    emit("cuda_available_error", f"{type(exc).__name__}:{exc}")
emit("cuda_available", str(cuda_available).lower())

try:
    device_count = int(torch.cuda.device_count()) if cuda_available else 0
except BaseException:
    device_count = 0
emit("cuda_device_count", device_count)

gpu_name = "unavailable"
compute_capability = "unavailable"
if not cuda_available or device_count < 1:
    emit("gpu_name", gpu_name)
    emit("compute_capability", compute_capability)
    emit("cuda_tensor", "not_run")
    status = 1
else:
    try:
        properties = torch.cuda.get_device_properties(0)
        gpu_name = str(properties.name)
        compute_capability = f"{properties.major}.{properties.minor}"
        emit("gpu_name", gpu_name)
        emit("compute_capability", compute_capability)
    except BaseException as exc:
        emit("gpu_name", gpu_name)
        emit("compute_capability", compute_capability)
        emit("cuda_device_error", f"{type(exc).__name__}:{exc}")
        status = 1

    try:
        tensor = torch.ones((1,), device="cuda")
        result = float((tensor + 1).item())
        torch.cuda.synchronize()
        if result != 2.0:
            raise RuntimeError(f"unexpected CUDA tensor result: {result}")
        emit("cuda_tensor", "ok")
    except BaseException as exc:
        emit("cuda_tensor", f"error:{type(exc).__name__}:{exc}")
        status = 1

blackwell = "RTX 50" in gpu_name.upper() or "BLACKWELL" in gpu_name.upper()
minimum_cuda = os.environ.get("BLACKWELL_MIN_CUDA", "12.8")
minimum_torch = os.environ.get("BLACKWELL_MIN_TORCH", "2.7")
compatibility_issues = []
if not version_at_least(torch_version, minimum_torch):
    compatibility_issues.append(f"PyTorch {torch_version} is below {minimum_torch}")
if not version_at_least(torch_cuda, minimum_cuda):
    compatibility_issues.append(f"PyTorch CUDA {torch_cuda} is below {minimum_cuda}")
if blackwell:
    if compatibility_issues:
        emit("blackwell_compatibility", "fail:" + "; ".join(compatibility_issues))
        status = 1
    else:
        emit("blackwell_compatibility", "pass")
else:
    if compatibility_issues:
        emit("blackwell_compatibility", "warning:" + "; ".join(compatibility_issues))
    else:
        emit("blackwell_compatibility", "not_required")

emit("probe_status", "ok" if status == 0 else "failed")
raise SystemExit(status)
PY
}

write_torch_constraints() {
  local report="$1"
  local destination="$2"
  local package
  local version

  : > "$destination"
  for package in torch torchvision torchaudio; do
    version="$(report_value "${package}_version" "$report")"
    if [[ -n "$version" && "$version" != 'unavailable' && "$version" != error:* ]]; then
      printf '%s==%s\n' "$package" "$version" >> "$destination"
    fi
  done
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
