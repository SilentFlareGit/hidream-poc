#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

printf '%s\n' '=== Host validation ==='

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  printf 'Linux distribution: %s\n' "${PRETTY_NAME:-unknown}"
else
  printf '%s\n' 'Linux distribution: /etc/os-release unavailable'
fi
printf 'Kernel: %s\n' "$(uname -srmo)"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  die 'nvidia-smi was not found. Use a Vast PyTorch instance with NVIDIA drivers and GPU access.'
fi
if ! smi_output="$(nvidia-smi 2>/dev/null)"; then
  die 'nvidia-smi exists but failed. Check the NVIDIA driver, GPU assignment, and container runtime.'
fi
if ! gpu_info="$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null)"; then
  die 'nvidia-smi could not query GPU name, VRAM, and driver information.'
fi
[[ -n "$gpu_info" ]] || die 'nvidia-smi returned no GPU records. NVIDIA GPU access is unavailable.'

cuda_reported="$(awk -F 'CUDA Version: ' '/CUDA Version:/ { split($2, value, " "); print value[1]; exit }' <<<"$smi_output")"
cuda_reported="${cuda_reported:-unreported}"
printf 'GPU name / VRAM / NVIDIA driver:\n%s\n' "$gpu_info"
printf 'CUDA version reported by nvidia-smi: %s\n' "$cuda_reported"

printf '%s\n' 'CPU summary:'
if cpu_summary="$(lscpu 2>/dev/null)"; then
  printf '%s\n' "$cpu_summary" | awk -F: '/^(Model name|CPU\(s\)|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)):/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $1 ": " $2 }'
else
  awk -F: '/^(model name|processor):/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $1 ": " $2; count++ } END { print "processors listed: " count }' /proc/cpuinfo 2>/dev/null || printf '%s\n' 'CPU details unavailable'
fi

printf '%s\n' 'RAM summary:'
if ! free -h 2>/dev/null; then
  awk '/^(MemTotal|MemAvailable|SwapTotal):/ { print }' /proc/meminfo 2>/dev/null || printf '%s\n' 'RAM details unavailable'
fi

printf '%s\n' "Disk usage for $POC_ROOT:"
if ! df -h "$POC_ROOT"; then
  printf '%s\n' 'Disk usage unavailable'
fi

PYTHON_BIN=''
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python)"
fi
if [[ -n "$PYTHON_BIN" ]]; then
  if python_version="$("$PYTHON_BIN" --version 2>&1)"; then
    printf 'Python version: %s\n' "$python_version"
  else
    printf 'Python version: unavailable (%s)\n' "$python_version"
  fi
else
  printf '%s\n' 'Python version: unavailable'
fi

if command -v git >/dev/null 2>&1; then
  if git_version="$(git --version 2>&1)"; then
    printf 'Git version: %s\n' "$git_version"
  else
    printf 'Git version: unavailable (%s)\n' "$git_version"
  fi
else
  printf '%s\n' 'Git version: unavailable'
fi

if [[ -n "$PYTHON_BIN" ]] && "$PYTHON_BIN" -c 'import torch' >/dev/null 2>&1; then
  "$PYTHON_BIN" - <<'PY'
import torch

print(f"PyTorch version: {torch.__version__}")
print(f"torch.cuda.is_available(): {torch.cuda.is_available()}")
print(f"PyTorch CUDA version: {torch.version.cuda or 'unreported'}")
PY
else
  printf '%s\n' 'PyTorch: not installed or could not be imported'
fi

validate_port 'COMFYUI_PORT' "$COMFYUI_PORT"
if port_in_use "$COMFYUI_PORT"; then
  printf 'TCP port %s: IN USE\n' "$COMFYUI_PORT"
else
  port_status=$?
  case "$port_status" in
    1) printf 'TCP port %s: available\n' "$COMFYUI_PORT" ;;
    2) printf 'TCP port %s: unable to inspect (install ss or lsof)\n' "$COMFYUI_PORT" ;;
    *) die "could not determine whether TCP port $COMFYUI_PORT is in use" ;;
  esac
fi

printf '%s\n' 'Host validation completed.'
