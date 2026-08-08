# AGENTS.md — Codex instructions

## Mission

Build a minimal, reproducible technical PoC for local AI image generation on a rented NVIDIA GPU VM.

The environment must run ComfyUI locally and support two model tracks:

1. Chroma1-HD for photorealistic/general image generation.
2. Pony Diffusion V6 XL for anime/illustration generation.

The primary test target is Vast.ai Secure Cloud using the official/standard PyTorch Vast template, typically on an RTX 5090 32 GB instance with at least 150 GB storage.

## Non-goals

Do NOT add any of the following unless the user explicitly expands scope:

- Kubernetes
- Terraform
- autoscaling
- multi-user auth platform
- public SaaS frontend
- object storage integration
- GHCR publishing
- CI/CD deployment pipelines
- billing system
- production SLA design
- telemetry / analytics SaaS
- third-party image generation APIs
- cloud prompt rewriting
- cloud moderation APIs

## Security requirements

- ComfyUI must not be exposed directly on a public interface.
- Bind ComfyUI to `127.0.0.1:8188` where the runtime allows it, or otherwise enforce equivalent local-only access and document the SSH tunnel.
- Never commit tokens, credentials, private images, model weights, or generated images.
- Do not add telemetry or remote analytics.
- Do not install arbitrary ComfyUI custom nodes just because they are popular.
- Every custom node must be justified by a concrete model/workflow requirement and documented before installation.
- Prefer official repositories and pinned revisions.

## Reproducibility requirements

- Pin ComfyUI to an explicit Git commit.
- Pin Python dependencies where practical.
- Record the base image/tag and relevant CUDA/PyTorch versions.
- Keep model URLs, filenames, expected destination directories, licenses, and hashes in a manifest rather than scattering download commands across scripts.
- Do not invent download URLs or SHA-256 hashes. If a value has not been verified, leave it clearly marked as unresolved.
- Model files stay outside Git.

## Shell requirements

All Bash scripts must start with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Scripts must be safe to run more than once when practical and must fail with actionable error messages.

## Target repository layout

```text
hidream-poc/
├── AGENTS.md
├── README.md
├── .env.example
├── .gitignore
├── docker/
│   ├── Dockerfile
│   └── compose.yaml
├── scripts/
│   ├── check-host.sh
│   ├── download-models.sh
│   ├── start.sh
│   ├── stop.sh
│   └── collect-metrics.sh
├── config/
│   └── models.yaml
├── workflows/
├── benchmark/
│   ├── prompts.example.json
│   └── results/
├── docs/
│   ├── POC_SCOPE.md
│   ├── ACCEPTANCE.md
│   └── TEST_REPORT.md
├── models/
├── input/
└── output/
```

## Implementation strategy

Work in small phases. Do not implement later phases early.

### Phase 1 — Host validation and ComfyUI runtime

Create host checks and a minimal ComfyUI runtime. Verify NVIDIA GPU access first. No model downloads yet.

### Phase 2 — Model manifest and downloads

Add verified manifests/download logic for Chroma1-HD and Pony Diffusion V6 XL. Keep model weights outside Git.

### Phase 3 — Workflows

Add one minimal known-good workflow per model. Do not add LoRAs, ControlNet, upscalers, or custom nodes until the baseline works.

### Phase 4 — Benchmark

Automate reproducible test runs and record model, seed, resolution, steps, execution time, GPU, peak VRAM if measurable, and output filename.

### Phase 5 — PoC report

Complete `docs/TEST_REPORT.md` using observed results only. Do not invent benchmark numbers.

## Content scope

This repository is infrastructure/model-evaluation code. Do not hard-code explicit prompts or private reference material into the repository. Benchmark prompt examples committed to Git should remain neutral and suitable for testing technical functionality. User-specific test prompts can remain local and untracked.

## Change discipline

Before editing:

1. Inspect existing files.
2. State the phase being implemented.
3. Avoid unrelated refactors.
4. After edits, run available syntax/config checks.
5. Summarize changed files, commands run, and unresolved items.
