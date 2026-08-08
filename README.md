# hidream-poc

Private/local AI image-generation proof of concept using ComfyUI on rented NVIDIA GPU compute.

## PoC goal

Prove that a reproducible ComfyUI environment can run two local model tracks on a rented GPU instance without relying on third-party image-generation APIs:

- **Chroma1-HD** — photorealistic / general image track.
- **Pony Diffusion V6 XL** — anime / illustration track.

The PoC is intentionally small. It validates deployment, GPU compatibility, image quality, performance, repeatability, and local-only inference. Production infrastructure is out of scope.

## Target test environment

Current preferred test target:

- Vast.ai Secure Cloud
- Verified host
- NVIDIA RTX 5090 32 GB or equivalent
- PyTorch (Vast) base template
- 150 GB+ container storage
- Host reliability >= 99.5%
- ComfyUI accessed through SSH tunneling; port 8188 must not be exposed directly to the public Internet.

## Repository policy

Do **not** commit:

- model weights
- generated images
- private reference images
- API keys / Hugging Face tokens
- `.env`

See `AGENTS.md` for implementation constraints and `docs/POC_SCOPE.md` for the project boundary.

## Initial status

Repository scaffold only. Implementation is intended to be completed with Codex in small, reviewable steps.
