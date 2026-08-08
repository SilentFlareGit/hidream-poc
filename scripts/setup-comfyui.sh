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

if [[ "$COMFYUI_PYTHON" == */* ]]; then
  PYTHON_BIN="$COMFYUI_PYTHON"
  [[ -x "$PYTHON_BIN" ]] || die "Configured COMFYUI_PYTHON is not executable: $PYTHON_BIN"
else
  PYTHON_BIN="$(command -v "$COMFYUI_PYTHON" || true)"
  [[ -n "$PYTHON_BIN" ]] || die "Python command not found: $COMFYUI_PYTHON"
fi

mkdir -p "$COMFYUI_RUNTIME_DIR"

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

if [[ ! -x "$COMFYUI_VENV_DIR/bin/python" ]]; then
  printf 'Creating Python environment with access to the Vast template packages...\n'
  "$PYTHON_BIN" -m venv --system-site-packages "$COMFYUI_VENV_DIR"
fi
VENV_PYTHON="$COMFYUI_VENV_DIR/bin/python"
[[ -x "$VENV_PYTHON" ]] || die "Python virtual environment was not created: $COMFYUI_VENV_DIR"
[[ -f "$COMFYUI_DIR/requirements.txt" ]] || die "ComfyUI requirements.txt is missing at the pinned commit"

printf 'Installing dependencies from the pinned ComfyUI requirements.txt...\n'
PIP_DISABLE_PIP_VERSION_CHECK=1 "$VENV_PYTHON" -m pip install --requirement "$COMFYUI_DIR/requirements.txt"

printf '%s\n' 'ComfyUI setup completed.'
printf 'Checkout: %s\n' "$COMFYUI_DIR"
printf 'Commit:   %s\n' "$actual_commit"
printf 'Python:   %s\n' "$VENV_PYTHON"
printf '%s\n' 'No models or custom nodes were installed.'
