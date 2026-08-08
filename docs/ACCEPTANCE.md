# PoC Acceptance Criteria

The PoC passes when all applicable checks below are supported by observed evidence.

- [ ] Host GPU and driver information captured.
- [ ] ComfyUI runtime starts successfully.
- [ ] ComfyUI is reachable through an SSH tunnel/local-only access path.
- [ ] Public direct access to port 8188 is not required.
- [ ] Chroma1-HD baseline workflow loads and generates successfully.
- [ ] Pony Diffusion V6 XL baseline workflow loads and generates successfully.
- [ ] At least one 1024-class image generation is demonstrated where supported by the selected workflow/model.
- [ ] Generation duration is recorded.
- [ ] GPU model and VRAM are recorded.
- [ ] Peak VRAM is recorded when practical.
- [ ] Model filenames/revisions and source references are documented.
- [ ] Model weights and private outputs are absent from Git history.
- [ ] A clean setup procedure is documented.
- [ ] `docs/TEST_REPORT.md` contains actual test results and known limitations.
