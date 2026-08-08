# hidream-poc

Private/local AI image-generation proof of concept using ComfyUI on rented NVIDIA GPU compute.

## Phase 1 status

Phase 1 provides host validation and a minimal direct ComfyUI runtime for the Vast.ai PyTorch template. Later phases will cover the Chroma1-HD and Pony Diffusion V6 XL tracks. This phase does not download model weights, install custom nodes, add ComfyUI Manager, or create workflows.

The intended test target is a verified Vast.ai Secure Cloud host with the standard Vast PyTorch image, 150 GB or more of storage, and an NVIDIA GPU. The scripts do not hard-code a GPU model.

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

`setup-comfyui.sh` clones only `https://github.com/Comfy-Org/ComfyUI.git`, checks out the configured commit, creates `.runtime/venv` with access to packages supplied by the Vast PyTorch image, and installs the pinned checkout's official `requirements.txt`. It does not download models or custom nodes.

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
- `COMFYUI_HOST`: `127.0.0.1` by default.
- `COMFYUI_PORT`: `8188` by default.
- `SSH_TUNNEL_HOST`, `SSH_TUNNEL_PORT`, and `SSH_TUNNEL_USER`: only used to print the tunnel command.
- `SSH_LOCAL_PORT`: local browser port, normally `8188`.

If Vast requires ComfyUI to listen on a non-loopback interface for its forwarding path, set `COMFYUI_HOST` deliberately and set `COMFYUI_ALLOW_NON_LOOPBACK=1` only after reviewing the instance firewall and network exposure. The start script warns because this can make the port publicly reachable. It never broadens the bind address automatically.

## Troubleshooting

### `nvidia-smi` is unavailable

The host is not passing through an NVIDIA GPU or driver to the container. Confirm that the instance uses a Vast PyTorch template and a GPU-enabled rental, then reconnect or redeploy. Do not continue to model setup until `bash scripts/check-host.sh` succeeds.

### `torch.cuda.is_available()` is false

Compare the Python and PyTorch reported by `check-host.sh` with the template's CUDA/PyTorch installation. A CPU-only or mismatched PyTorch installation must be corrected in the host environment before continuing. Phase 1 does not install or select a replacement CUDA stack.

### Dependency installation fails

Read the command output and the pinned checkout's `requirements.txt`. Confirm outbound access to GitHub/PyPI, Python 3, and available disk space, then rerun `bash scripts/setup-comfyui.sh`. No model files are needed for this phase.

### Port 8188 is already occupied

`check-host.sh` reports the port status and `start.sh` refuses to take an occupied port. Inspect the owner with `ss -ltnp | grep ':8188'`, stop only the process you recognize, or set another `COMFYUI_PORT` and matching `SSH_LOCAL_PORT` in `.env`.

### A stale PID file is present

Run `bash scripts/stop.sh`. It removes invalid or stale PID files. If the PID points to a live unrelated process, the script refuses to signal it; inspect the PID file and process before taking any manual action.

### The Vast instance restarted

Reconnect over SSH, verify the repository and `.env` are present, run `bash scripts/check-host.sh`, rerun `bash scripts/setup-comfyui.sh` if the runtime directory was lost, and then run `bash scripts/start.sh`. The explicit commit in `.env` prevents the ComfyUI checkout from drifting during setup.

## Runtime data and scope

Runtime state is stored under `.runtime/` and ignored by Git. Model weights, input images, generated output images, logs, PID files, virtual environments, and caches are also ignored. See `AGENTS.md`, `docs/POC_SCOPE.md`, and `docs/ACCEPTANCE.md` for the project boundary and evidence requirements.

Phase 2 will add verified model manifests and download logic only after this Phase 1 runtime has been reviewed.
