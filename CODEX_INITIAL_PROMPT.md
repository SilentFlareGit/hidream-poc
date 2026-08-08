# Initial Codex prompt

Read `AGENTS.md`, `README.md`, `docs/POC_SCOPE.md`, and `docs/ACCEPTANCE.md` before making changes.

We are implementing **Phase 1 only: host validation + minimal ComfyUI runtime** for the `hidream-poc` repository.

Current target environment:

- Vast.ai Secure Cloud
- Verified host
- Vast PyTorch base template
- NVIDIA RTX 5090 32 GB is the expected first test GPU, but the scripts must not hard-code that GPU model
- 150 GB+ storage
- Linux shell with root or sufficient package permissions

For this phase, implement:

1. `scripts/check-host.sh`
   - print OS/kernel information
   - verify `nvidia-smi` exists and succeeds
   - print GPU model, driver, CUDA-reported version and total VRAM
   - print CPU/RAM/disk summary
   - check Python and Git
   - check whether port 8188 is already in use
   - exit non-zero with a useful message if NVIDIA GPU access is unavailable

2. A minimal ComfyUI runtime.
   - Prefer the simplest solution compatible with the Vast PyTorch template.
   - Do not assume Docker-in-Docker is available. Inspect the environment first and document the chosen approach.
   - Clone ComfyUI only from the official Comfy-Org/ComfyUI repository.
   - Add a mechanism to pin an explicit ComfyUI commit.
   - Do not install ComfyUI Manager.
   - Do not install third-party custom nodes.
   - Do not download any AI model weights in Phase 1.

3. `scripts/start.sh`
   - start ComfyUI reproducibly
   - use local-only binding where technically supported
   - make the intended SSH tunnel command obvious in its output
   - log PID/log-file location if running as a background process

4. `scripts/stop.sh`
   - stop only the ComfyUI process started by this repository
   - be idempotent

5. Update `README.md`
   - exact Phase 1 setup/run commands for a fresh Vast PyTorch instance
   - SSH tunnel instructions
   - validation commands
   - troubleshooting notes for GPU visibility and port 8188

Constraints:

- Follow every rule in `AGENTS.md`.
- No Kubernetes, Terraform, GHCR, CI/CD, object storage, auth platform, or production architecture.
- No model downloads yet.
- No arbitrary custom nodes.
- No telemetry.
- Do not fabricate package versions, URLs, model hashes, or benchmark numbers.
- Do not expose ComfyUI directly to the public Internet.
- Keep changes small and reviewable.

Before editing, inspect the repository and explain the implementation plan in 5-10 concise bullets.

After editing:

- run shell syntax checks (`bash -n`) on every shell script
- run any safe config/static checks that do not require a GPU
- show the final directory tree
- summarize changed files
- list commands I must run on the Vast instance
- explicitly state anything that still needs real-GPU verification

Stop after Phase 1. Do not proceed to model downloads or workflows until I review the result.
