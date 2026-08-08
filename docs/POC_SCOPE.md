# PoC Scope

## Objective

Validate a private/local ComfyUI inference stack on rented NVIDIA GPU compute.

## Required model tracks

- Chroma1-HD
- Pony Diffusion V6 XL

## Required validations

- NVIDIA GPU is visible to the runtime.
- ComfyUI starts reproducibly.
- ComfyUI is not directly exposed to the public Internet.
- Both model tracks can produce images at useful resolutions.
- Model loading fits the selected GPU strategy.
- Generation time and VRAM behavior are recorded.
- The deployment can be recreated from repository instructions without reinstalling everything manually from memory.

## Out of scope

Production hardening, commercial deployment, multi-user access, autoscaling, Kubernetes, Terraform, persistent cloud storage architecture, formal compliance review, and high availability.
