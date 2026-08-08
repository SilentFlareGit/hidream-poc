# hidream-poc

Private/local AI image-generation proof of concept using ComfyUI on rented NVIDIA GPU compute.

## Phase 1 status

Phase 1 provides host validation and a minimal direct ComfyUI runtime for the Vast.ai PyTorch template. Phase 2 adds a verified model manifest, guarded downloads, and static baseline workflows for the Chroma1-HD and Pony Diffusion V6 XL tracks. This repository still does not install custom nodes, add ComfyUI Manager, or download models during development validation.

The intended test target is a verified Vast.ai Secure Cloud host with the standard Vast PyTorch image, 150 GB or more of storage, and an NVIDIA GPU. The scripts do not hard-code a GPU model.

The recommended Vast PyTorch template supplies the working interpreter at `/venv/main/bin/python`. For an RTX 50-series or other Blackwell GPU, the runtime must provide CUDA 12.8 or newer compatibility and PyTorch 2.7 or newer. `check-host.sh` must pass a real CUDA tensor operation before setup continues.

ComfyUI binds to `127.0.0.1:8188` by default. It is not intended to be exposed directly to the public Internet. Access it through an SSH tunnel from the local computer.

## Fresh Vast.ai setup

Run these commands in an SSH session on the new instance:

```bash
git clone <YOUR_HIDREAM_POC_REPOSITORY_URL> hidream-poc
cd hidream-poc
cp .env.example .env
```

Choose and review an upstream ComfyUI commit, then put its full 40-character ID in `.env`:

```bash
git ls-remote https://github.com/Comfy-Org/ComfyUI.git HEAD
${EDITOR:-vi} .env
```

Do not leave `COMFYUI_COMMIT` empty. The setup script rejects branch names, tags, placeholders, and non-40-character values. The `HEAD` command only shows the current upstream default-branch commit; review the commit you intend to pin before saving it.

Validate the host and install the pinned runtime:

```bash
bash scripts/check-host.sh
bash scripts/setup-comfyui.sh
```

`setup-comfyui.sh` clones only `https://github.com/Comfy-Org/ComfyUI.git`, checks out the configured commit, selects `/venv/main/bin/python` when available, and installs the pinned checkout's official `requirements.txt` into that same environment. It protects the existing PyTorch, CUDA, torchvision, and torchaudio versions with constraints and verifies the environment before and after installation. It does not create a nested virtual environment, download models, or install custom nodes.

Start ComfyUI:

```bash
bash scripts/start.sh
```

The script prints the PID, log path, and an SSH tunnel command. From the local computer, run the printed command, replacing the placeholder host and SSH port with the values shown by Vast.ai if they are not already set in `.env`:

```bash
ssh -N -L 8188:127.0.0.1:8188 -p 22 root@YOUR_VAST_SSH_HOST
```

Keep that tunnel open and open [http://127.0.0.1:8188](http://127.0.0.1:8188) in the local browser. Stop ComfyUI on the Vast instance with:

```bash
bash scripts/stop.sh
```

The scripts are safe to rerun. Start refuses a duplicate instance and stop handles missing or stale PID files without touching unrelated processes.

## Configuration

Copy `.env.example` to `.env` before setup. `.env` is ignored by Git. The important values are:

- `COMFYUI_COMMIT`: required, reviewed 40-character commit ID.
- `COMFYUI_PYTHON`: blank by default, which prefers `/venv/main/bin/python`; set an explicit executable only when intentionally overriding it.
- `COMFYUI_HOST`: `127.0.0.1` by default.
- `COMFYUI_PORT`: `8188` by default.
- `SSH_TUNNEL_HOST`, `SSH_TUNNEL_PORT`, and `SSH_TUNNEL_USER`: only used to print the tunnel command.
- `SSH_LOCAL_PORT`: local browser port, normally `8188`.

When upgrading an existing Phase 1 `.env`, remove any legacy nested-environment setting and clear `COMFYUI_PYTHON=python3` if you want the automatic `/venv/main/bin/python` preference. A non-empty `COMFYUI_PYTHON` is treated as an intentional override.

The ComfyUI Git commit pins the source checkout only. Python dependencies are resolved by pip from the pinned checkout's `requirements.txt` inside the existing Vast environment; this is not a complete dependency lock. The setup script refuses to replace the working core PyTorch stack and reports before/after values if the environment changes.

If Vast requires ComfyUI to listen on a non-loopback interface for its forwarding path, set `COMFYUI_HOST` deliberately and set `COMFYUI_ALLOW_NON_LOOPBACK=1` only after reviewing the instance firewall and network exposure. The start script warns because this can make the port publicly reachable. It never broadens the bind address automatically.

## Phase 2 model setup

Phase 2 is intended to run on the already validated Vast instance. The recommended Vast PyTorch template supplies `/venv/main/bin/python`; the model scripts use the same interpreter selected by the Phase 1 runtime. For an RTX 5090 or another RTX 50-series/Blackwell GPU, use a CUDA 12.8-compatible environment with PyTorch 2.7 or newer. `check-host.sh` must pass a real CUDA tensor operation before continuing.

`config/models.json` is the checked-in machine-readable artifact manifest. It records the canonical repository, HTTPS source URL, destination filename, SHA-256, known size, and license metadata. It does not contain credentials, model files, cookies, or temporary URLs. The downloader does not use Hugging Face login, install packages, add custom nodes, install Manager, or download anything outside the manifest.

The manifest pins model source artifacts and hashes. That is separate from Python dependency resolution: the ComfyUI Git commit pins the source checkout, while the pinned checkout's `requirements.txt` is resolved by pip in the existing Vast environment. A Git commit alone does not make all Python dependency versions fully reproducible.

Approximate storage planning:

- Pony V6 XL: 6,938,041,050 bytes, about 6.5 GiB, plus at least 10 GiB free after download.
- Chroma's text encoder plus autoencoder: 5,492,653,076 bytes, about 5.1 GiB, plus the Chroma1-HD BF16 file.
- The canonical Chroma1-HD manifest intentionally does not invent an expected size. The downloader resolves its remote size before downloading it.
- The full BF16 Chroma diffusion track requires real 32 GB GPU validation; this repository does not claim that it fits. Alternative quantized diffusion-model fallbacks are outside Phase 2.

The canonical Pony artifact has an upstream license review requirement. This phase is for a personal/local PoC only; review the upstream terms before any commercial, monetized, or redistributed deployment.

Run this exact sequence on the already-running Vast checkout:

```bash
cd /workspace/hidream-poc
git pull
bash scripts/verify-models.sh --model all   # expected fail before download
bash scripts/download-models.sh --dry-run --model all
bash scripts/download-models.sh --model pony
bash scripts/verify-models.sh --model pony
bash scripts/download-models.sh --model chroma
bash scripts/verify-models.sh --model chroma
bash scripts/stop.sh
bash scripts/start.sh
```

The downloader creates only the manifest destinations under the pinned ComfyUI checkout. It skips valid final files, refuses to overwrite an invalid final file, resumes `<filename>.part` files where the HTTPS server supports ranges, verifies size and SHA-256, and atomically renames a verified part into place. `--dry-run` performs no downloads; `--verify-only` reports each requested artifact and exits non-zero for a missing or invalid required file. No external/public network access is required for ComfyUI readiness checks, and port 8188 remains loopback-only by default.

After restart, load `workflows/pony-v6-xl-basic.json` or `workflows/chroma1-hd-basic.json` through the ComfyUI browser. These are static core-node fixtures with deterministic one-image, 1024x1024 settings. Static JSON validation does not prove that the pinned ComfyUI commit, model files, or RTX 5090 runtime will execute them successfully; that evidence belongs to a real Vast run. The Pony workflow uses the core SDXL checkpoint loader and CLIP last-layer setting `-2`, with no refiner, LoRA, embeddings, or custom nodes.

## Troubleshooting

### `nvidia-smi` is unavailable

The host is not passing through an NVIDIA GPU or driver to the container. Confirm that the instance uses a Vast PyTorch template and a GPU-enabled rental, then reconnect or redeploy. Do not continue to model setup until `bash scripts/check-host.sh` succeeds.

### `torch.cuda.is_available()` is false

Compare the Python and PyTorch reported by `check-host.sh` with the template's CUDA/PyTorch installation. A CPU-only or mismatched PyTorch installation must be corrected in the host environment before continuing. For RTX 5090/Blackwell, confirm CUDA 12.8 or newer compatibility and PyTorch 2.7 or newer. Phase 1.1 does not install or select a replacement CUDA stack.

### Dependency installation fails

Read the before/after PyTorch reports and the pinned checkout's `requirements.txt`. Confirm outbound access to GitHub/PyPI, the `/venv/main/bin/python` environment, and available disk space, then correct the host environment before rerunning `bash scripts/setup-comfyui.sh`. No model files are needed for this phase.

### Port 8188 is already occupied

`check-host.sh` reports the port status and `start.sh` refuses to take an occupied port. Inspect the owner with `ss -ltnp | grep ':8188'`, stop only the process you recognize, or set another `COMFYUI_PORT` and matching `SSH_LOCAL_PORT` in `.env`.

### A stale PID file is present

Run `bash scripts/stop.sh`. It removes invalid or stale PID files. If the PID points to a live unrelated process, the script refuses to signal it; inspect the PID file and process before taking any manual action.

### The Vast instance restarted

Reconnect over SSH, verify the repository and `.env` are present, run `bash scripts/check-host.sh`, rerun `bash scripts/setup-comfyui.sh` if the runtime directory was lost, and then run `bash scripts/start.sh`. The explicit commit in `.env` prevents the ComfyUI checkout from drifting during setup.

## Runtime data and scope

Runtime state is stored under `.runtime/` and ignored by Git. Model weights, input images, generated output images, logs, PID files, and caches are also ignored. See `AGENTS.md`, `docs/POC_SCOPE.md`, and `docs/ACCEPTANCE.md` for the project boundary and evidence requirements.

Phase 2 stops at the verified manifest, guarded downloads, static baseline workflow fixtures, and their validators. No Phase 3 workflow expansion, benchmark automation, or runtime evidence is part of this patch.
