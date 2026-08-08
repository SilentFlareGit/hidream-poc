#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if [[ "$COMFYUI_REPO" != "$OFFICIAL_COMFYUI_REPO" ]]; then
  die "COMFYUI_REPO must be exactly $OFFICIAL_COMFYUI_REPO"
fi
if [[ -z "$COMFYUI_COMMIT" ]]; then
  die 'COMFYUI_COMMIT is empty. Set it to an explicit 40-character ComfyUI commit in .env before setup.'
fi
if ! [[ "$COMFYUI_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
  die "COMFYUI_COMMIT must be a 40-character commit ID, not '$COMFYUI_COMMIT'"
fi
if ! command -v git >/dev/null 2>&1; then
  die 'Git is required to install ComfyUI.'
fi

if ! PYTHON_BIN="$(resolve_python_executable "$COMFYUI_PYTHON")"; then
  die "COMFYUI_PYTHON could not be resolved: $COMFYUI_PYTHON"
fi
printf 'Python executable (%s): %s\n' "$COMFYUI_PYTHON_SOURCE" "$PYTHON_BIN"

mkdir -p "$COMFYUI_RUNTIME_DIR" "$(dirname "$COMFYUI_DIR")"

if [[ -d "$COMFYUI_DIR/.git" || -f "$COMFYUI_DIR/.git" ]]; then
  if ! git -C "$COMFYUI_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "ComfyUI directory is not a valid Git checkout: $COMFYUI_DIR"
  fi
elif [[ -e "$COMFYUI_DIR" ]]; then
  if [[ -n "$(find "$COMFYUI_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    die "ComfyUI directory exists and is not an empty Git checkout: $COMFYUI_DIR"
  fi
  git clone "$COMFYUI_REPO" "$COMFYUI_DIR"
else
  git clone "$COMFYUI_REPO" "$COMFYUI_DIR"
fi

origin_url="$(git -C "$COMFYUI_DIR" remote get-url origin 2>/dev/null || true)"
[[ "$origin_url" == "$OFFICIAL_COMFYUI_REPO" ]] || die "ComfyUI origin is not the official repository: $origin_url"

if [[ -n "$(git -C "$COMFYUI_DIR" status --porcelain)" ]]; then
  die "ComfyUI checkout has local changes. Review them before setup: $COMFYUI_DIR"
fi

if ! git -C "$COMFYUI_DIR" cat-file -e "$COMFYUI_COMMIT^{commit}" 2>/dev/null; then
  printf 'Fetching the configured ComfyUI commit...\n'
  git -C "$COMFYUI_DIR" fetch --quiet origin "$COMFYUI_COMMIT"
fi
git -C "$COMFYUI_DIR" checkout --detach --quiet "$COMFYUI_COMMIT"

actual_commit="$(git -C "$COMFYUI_DIR" rev-parse HEAD)"
expected_commit="$(printf '%s' "$COMFYUI_COMMIT" | tr '[:upper:]' '[:lower:]')"
[[ "$actual_commit" == "$expected_commit" ]] || die "Checked out commit $actual_commit instead of $expected_commit"
[[ -f "$COMFYUI_DIR/requirements.txt" ]] || die "ComfyUI requirements.txt is missing at the pinned commit"

before_ok=1
if before_report="$(torch_probe "$PYTHON_BIN")"; then
  :
else
  before_ok=0
fi
printf '%s\n' 'PyTorch environment before dependency installation:'
printf '%s\n' "${before_report:-<no report>}"
[[ "$before_ok" -eq 1 ]] || die 'The selected Vast PyTorch environment failed the required CUDA/PyTorch preflight; requirements were not installed.'

constraints_file="$COMFYUI_RUNTIME_DIR/torch-constraints.txt"
write_torch_constraints "$before_report" "$constraints_file"
printf 'Protecting the working PyTorch stack with constraints: %s\n' "$constraints_file"

pip_ok=1
if ! PIP_DISABLE_PIP_VERSION_CHECK=1 "$PYTHON_BIN" -m pip install --requirement "$COMFYUI_DIR/requirements.txt" --constraint "$constraints_file"; then
  pip_ok=0
  printf '%s\n' 'Dependency installation failed; checking the PyTorch environment before exiting.' >&2
fi

after_ok=1
if after_report="$(torch_probe "$PYTHON_BIN")"; then
  :
else
  after_ok=0
fi
printf '%s\n' 'PyTorch environment after dependency installation:'
printf '%s\n' "${after_report:-<no report>}"

for key in torch_version torch_cuda torch_file; do
  before_value="$(report_value "$key" "$before_report")"
  after_value="$(report_value "$key" "$after_report")"
  if [[ "$before_value" != "$after_value" ]]; then
    printf 'ERROR: %s changed during dependency installation. Before: %s. After: %s.\n' "$key" "${before_value:-<missing>}" "${after_value:-<missing>}" >&2
    pip_ok=0
  fi
done

if [[ "$pip_ok" -ne 1 || "$after_ok" -ne 1 ]]; then
  die 'ComfyUI dependency installation did not preserve a working CUDA PyTorch environment. Review the before/after report above.'
fi

printf '%s\n' "$PYTHON_BIN" > "$COMFYUI_PYTHON_STATE_FILE"

printf '%s\n' 'ComfyUI setup completed.'
printf 'Checkout: %s\n' "$COMFYUI_DIR"
printf 'Commit:   %s\n' "$actual_commit"
printf 'Python:   %s\n' "$PYTHON_BIN"
printf '%s\n' 'No models or custom nodes were installed.'
