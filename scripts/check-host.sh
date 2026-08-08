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

smi_gpu_name="$(awk -F',' 'NR == 1 { gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1; exit }' <<<"$gpu_info")"
nvidia_smi_driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | awk 'NR == 1 { gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }' || true)"
nvidia_smi_driver="${nvidia_smi_driver:-unreported}"
cuda_reported="$(awk -F 'CUDA Version: ' '/CUDA Version:/ { split($2, value, " "); print value[1]; exit }' <<<"$smi_output")"
cuda_reported="${cuda_reported:-unreported}"

printf 'GPU name / VRAM / NVIDIA driver:\n%s\n' "$gpu_info"
printf 'NVIDIA-SMI driver version: %s\n' "$nvidia_smi_driver"
printf 'CUDA compatibility version reported by nvidia-smi: %s\n' "$cuda_reported"

if ! PYTHON_BIN="$(resolve_python_executable "$COMFYUI_PYTHON")"; then
  die "COMFYUI_PYTHON could not be resolved: $COMFYUI_PYTHON"
fi
printf 'Python executable (%s): %s\n' "$COMFYUI_PYTHON_SOURCE" "$PYTHON_BIN"

probe_ok=1
if torch_report="$(torch_probe "$PYTHON_BIN")"; then
  :
else
  probe_ok=0
fi
printf '%s\n' 'PyTorch/CUDA validation:'
printf '%s\n' "${torch_report:-<no report>}"

torch_gpu_name="$(report_value gpu_name "$torch_report")"
if [[ -n "$torch_gpu_name" && "$torch_gpu_name" != 'unavailable' ]]; then
  selected_gpu_name="$torch_gpu_name"
else
  selected_gpu_name="$smi_gpu_name"
fi
blackwell_smi_ok=1
if is_blackwell_gpu_name "$selected_gpu_name"; then
  if version_at_least "$cuda_reported" "$BLACKWELL_MIN_CUDA"; then
    printf 'Blackwell compatibility: nvidia-smi reports CUDA %s (minimum %s)\n' "$cuda_reported" "$BLACKWELL_MIN_CUDA"
  else
    printf 'ERROR: Blackwell compatibility failed: nvidia-smi reports CUDA %s, but CUDA %s or newer is required.\n' "$cuda_reported" "$BLACKWELL_MIN_CUDA" >&2
    blackwell_smi_ok=0
  fi
fi

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

if [[ "$probe_ok" -ne 1 || "$blackwell_smi_ok" -ne 1 ]]; then
  die 'Host validation failed. PyTorch must import and pass a real CUDA tensor operation before setup or startup.'
fi

printf '%s\n' 'Host validation completed.'
