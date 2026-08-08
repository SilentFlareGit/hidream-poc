#!/usr/bin/env python3
"""Download and verify the checked-in Phase 2 model manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


REQUIRED_FIELDS = (
    "id",
    "model_family",
    "role",
    "source_repository",
    "source_url",
    "filename",
    "destination_relative_to_comfyui",
    "sha256",
    "license_metadata",
    "license_review_required",
)
KEEP_FREE_BYTES = 10 * 1024 * 1024 * 1024
MAX_ATTEMPTS = 4
RETRYABLE_HTTP_CODES = {408, 429, 500, 502, 503, 504}
OFFICIAL_COMFYUI_REPO = "https://github.com/Comfy-Org/ComfyUI.git"


class ModelError(RuntimeError):
    """An actionable manifest, filesystem, network, or integrity error."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--comfyui-dir", type=Path, required=True)
    parser.add_argument("--model", choices=("pony", "chroma", "all"), default="all")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.dry_run and args.verify_only:
        parser.error("--dry-run and --verify-only cannot be combined")
    return args


def fail(message: str) -> None:
    raise ModelError(message)


def load_manifest(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        fail(f"model manifest not found: {path}")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"could not read model manifest {path}: {exc}")
    if not isinstance(document, dict) or not isinstance(document.get("artifacts"), list):
        fail("model manifest must contain an artifacts array")

    artifacts: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for index, artifact in enumerate(document["artifacts"]):
        if not isinstance(artifact, dict):
            fail(f"manifest artifact {index} is not an object")
        missing = [field for field in REQUIRED_FIELDS if field not in artifact]
        if missing:
            fail(f"manifest artifact {index} is missing: {', '.join(missing)}")
        artifact_id = artifact["id"]
        if not isinstance(artifact_id, str) or not artifact_id or artifact_id in seen_ids:
            fail(f"manifest artifact {index} has a missing or duplicate id: {artifact_id!r}")
        seen_ids.add(artifact_id)
        url = artifact["source_url"]
        if not isinstance(url, str) or urlparse(url).scheme.lower() != "https":
            fail(f"{artifact_id}: source_url must use HTTPS")
        digest = artifact["sha256"]
        if not isinstance(digest, str) or len(digest) != 64 or any(char not in "0123456789abcdefABCDEF" for char in digest):
            fail(f"{artifact_id}: sha256 must be a 64-character hexadecimal digest")
        destination = artifact["destination_relative_to_comfyui"]
        if not isinstance(destination, str) or not destination or Path(destination).is_absolute():
            fail(f"{artifact_id}: destination must be a relative path")
        if any(part == ".." for part in Path(destination).parts):
            fail(f"{artifact_id}: destination must not contain '..'")
        expected_size = artifact.get("expected_size_bytes")
        if expected_size is not None and (not isinstance(expected_size, int) or expected_size <= 0):
            fail(f"{artifact_id}: expected_size_bytes must be a positive integer or null")
        for field in ("id", "model_family", "role", "source_repository", "filename", "license_metadata"):
            if not isinstance(artifact[field], str) or not artifact[field]:
                fail(f"{artifact_id}: {field} must be a non-empty string")
        if not isinstance(artifact["license_review_required"], bool):
            fail(f"{artifact_id}: license_review_required must be boolean")
        artifact["sha256"] = digest.lower()
        artifacts.append(artifact)
    return artifacts


def selected_artifacts(artifacts: list[dict[str, Any]], model: str) -> list[dict[str, Any]]:
    if model == "all":
        return artifacts
    return [artifact for artifact in artifacts if artifact["model_family"] == model]


def ensure_checkout(comfyui_dir: Path) -> Path:
    checkout = comfyui_dir.expanduser().resolve()
    if not checkout.is_dir() or not (checkout / "main.py").is_file():
        fail(f"ComfyUI checkout is missing or invalid: {checkout}. Run setup-comfyui.sh first.")
    if not (checkout / ".git").exists():
        fail(f"ComfyUI checkout is not a Git checkout: {checkout}")
    try:
        origin = subprocess.run(
            ["git", "-C", str(checkout), "remote", "get-url", "origin"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        fail(f"could not read the ComfyUI Git origin at {checkout}: {exc}")
    if origin != OFFICIAL_COMFYUI_REPO:
        fail(f"ComfyUI origin is not the official repository: {origin}")
    return checkout


def artifact_paths(checkout: Path, artifact: dict[str, Any]) -> tuple[Path, Path]:
    final_path = (checkout / artifact["destination_relative_to_comfyui"]).resolve()
    try:
        final_path.relative_to(checkout)
    except ValueError:
        fail(f"{artifact['id']}: destination escapes the ComfyUI checkout")
    part_path = final_path.with_name(final_path.name + ".part")
    return final_path, part_path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(16 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_final(artifact: dict[str, Any], final_path: Path, *, print_result: bool) -> bool:
    artifact_id = artifact["id"]
    if not final_path.is_file():
        if print_result:
            print(f"{artifact_id}: path={final_path} present=no bytes=0 sha256=missing status=MISSING")
        return False
    size = final_path.stat().st_size
    size_ok = artifact.get("expected_size_bytes") is None or size == artifact["expected_size_bytes"]
    digest = sha256_file(final_path)
    hash_ok = digest == artifact["sha256"]
    status = "OK" if size_ok and hash_ok else "INVALID"
    if print_result:
        hash_status = "ok" if hash_ok else f"mismatch({digest})"
        print(f"{artifact_id}: path={final_path} present=yes bytes={size} sha256={hash_status} status={status}")
    return size_ok and hash_ok


def response_content_length(response: Any) -> int | None:
    value = response.headers.get("Content-Length")
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def remote_size(url: str) -> int:
    """Read the remote size without downloading the artifact body."""
    last_error: Exception | None = None
    for method, headers in (("HEAD", {}), ("GET", {"Range": "bytes=0-0"})):
        try:
            request = Request(url, headers=headers, method=method)
            with urlopen(request, timeout=30) as response:
                final_url = response.geturl()
                if urlparse(final_url).scheme.lower() != "https":
                    fail(f"redirected to a non-HTTPS URL: {final_url}")
                content_length = response_content_length(response)
                if method == "GET":
                    content_range = response.headers.get("Content-Range", "")
                    if "/" in content_range:
                        content_length = int(content_range.rsplit("/", 1)[1])
                if content_length is not None and content_length > 0:
                    return content_length
                last_error = ModelError(f"{method} response did not report a usable size")
        except HTTPError as exc:
            last_error = exc
            if exc.code not in RETRYABLE_HTTP_CODES and method == "HEAD":
                continue
        except (OSError, ValueError, URLError) as exc:
            last_error = exc
    fail(f"could not determine remote size for {url}: {last_error}")


def check_final_conflicts(artifacts: list[dict[str, Any]], checkout: Path) -> dict[str, tuple[Path, Path]]:
    paths: dict[str, tuple[Path, Path]] = {}
    for artifact in artifacts:
        final_path, part_path = artifact_paths(checkout, artifact)
        paths[artifact["id"]] = (final_path, part_path)
        if final_path.exists() and not final_path.is_file():
            fail(f"{artifact['id']}: final destination is not a regular file: {final_path}")
        if final_path.is_file() and not inspect_final(artifact, final_path, print_result=False):
            fail(f"{artifact['id']}: existing final file is invalid; refusing to overwrite it: {final_path}")
    return paths


def plan_downloads(artifacts: list[dict[str, Any]], checkout: Path, paths: dict[str, tuple[Path, Path]], *, allow_network: bool) -> tuple[int, dict[str, int]]:
    planned_bytes = 0
    resolved_sizes: dict[str, int] = {}
    for artifact in artifacts:
        final_path, part_path = paths[artifact["id"]]
        if final_path.is_file():
            print(f"SKIP valid final: {artifact['id']} -> {final_path}")
            continue
        expected_size = artifact.get("expected_size_bytes")
        if expected_size is None:
            if not allow_network:
                print(f"PLAN size unresolved until download: {artifact['id']} -> {final_path}")
                continue
            expected_size = remote_size(artifact["source_url"])
            resolved_sizes[artifact["id"]] = expected_size
            print(f"Resolved remote size: {artifact['id']} = {expected_size} bytes")
        part_size = part_path.stat().st_size if part_path.is_file() else 0
        if part_size > expected_size:
            fail(f"{artifact['id']}: partial file is larger than expected; leaving it in place: {part_path}")
        remaining = expected_size - part_size
        planned_bytes += remaining
        print(f"PLAN download: {artifact['id']} bytes_remaining={remaining} destination={final_path}")
    return planned_bytes, resolved_sizes


def print_disk_plan(checkout: Path, planned_bytes: int) -> None:
    free_bytes = shutil.disk_usage(checkout).free
    after_bytes = free_bytes - planned_bytes
    print(f"Disk free bytes: {free_bytes}")
    print(f"Planned download bytes: {planned_bytes}")
    print(f"Projected free bytes after planned set: {after_bytes}")
    print(f"Required free bytes after planned set: {KEEP_FREE_BYTES}")
    if after_bytes < KEEP_FREE_BYTES:
        fail("insufficient disk space: the planned download set must leave at least 10 GiB free")


def download_artifact(artifact: dict[str, Any], final_path: Path, part_path: Path, resolved_size: int | None) -> None:
    expected_size = artifact.get("expected_size_bytes") or resolved_size
    if expected_size is None:
        fail(f"{artifact['id']}: download size was not resolved")
    part_path.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(1, MAX_ATTEMPTS + 1):
        part_size = part_path.stat().st_size if part_path.is_file() else 0
        headers = {"Range": f"bytes={part_size}-"} if part_size else {}
        request = Request(artifact["source_url"], headers=headers, method="GET")
        print(f"Downloading {artifact['id']} (attempt {attempt}/{MAX_ATTEMPTS}, resume_at={part_size})")
        try:
            with urlopen(request, timeout=60) as response:
                final_url = response.geturl()
                if urlparse(final_url).scheme.lower() != "https":
                    fail(f"{artifact['id']}: redirected to a non-HTTPS URL: {final_url}")
                status = getattr(response, "status", response.getcode())
                append = part_size > 0 and status == 206
                if part_size > 0 and status == 200:
                    print(f"{artifact['id']}: server ignored resume range; restarting the .part file")
                    part_size = 0
                    append = False
                if part_size > 0 and status != 206:
                    fail(f"{artifact['id']}: cannot resume partial download; HTTP status {status}")
                mode = "ab" if append else "wb"
                downloaded = part_size
                next_report = max(1, expected_size // 20)
                with part_path.open(mode) as stream:
                    while True:
                        chunk = response.read(16 * 1024 * 1024)
                        if not chunk:
                            break
                        stream.write(chunk)
                        downloaded += len(chunk)
                        if downloaded >= next_report or downloaded == expected_size:
                            percent = min(100.0, downloaded * 100.0 / expected_size)
                            print(f"  {artifact['id']}: {downloaded}/{expected_size} bytes ({percent:.1f}%)")
                            next_report += max(1, expected_size // 20)
                    stream.flush()
                    os.fsync(stream.fileno())
            actual_size = part_path.stat().st_size
            if actual_size != expected_size:
                raise ModelError(f"{artifact['id']}: downloaded size {actual_size} does not match expected {expected_size}; leaving .part")
            actual_hash = sha256_file(part_path)
            if actual_hash != artifact["sha256"]:
                raise ModelError(f"{artifact['id']}: SHA256 mismatch {actual_hash} != {artifact['sha256']}; leaving .part")
            if final_path.exists():
                fail(f"{artifact['id']}: final destination appeared during download; refusing to overwrite it: {final_path}")
            os.replace(part_path, final_path)
            print(f"Installed and verified: {artifact['id']} -> {final_path}")
            return
        except HTTPError as exc:
            if exc.code == 416 and part_path.is_file() and part_path.stat().st_size == expected_size:
                actual_hash = sha256_file(part_path)
                if actual_hash == artifact["sha256"] and not final_path.exists():
                    os.replace(part_path, final_path)
                    print(f"Installed and verified resumed file: {artifact['id']} -> {final_path}")
                    return
                fail(f"{artifact['id']}: server rejected the range and the partial file is not valid; leaving .part")
            if exc.code not in RETRYABLE_HTTP_CODES:
                fail(f"{artifact['id']}: HTTP {exc.code} while downloading; leaving .part")
            error: Exception = exc
        except (OSError, URLError, ModelError) as exc:
            error = exc
            if isinstance(exc, ModelError) and "leaving .part" not in str(exc):
                fail(str(exc))
        if attempt < MAX_ATTEMPTS:
            delay = 2 ** (attempt - 1)
            print(f"{artifact['id']}: {error}; retrying in {delay}s", file=sys.stderr)
            time.sleep(delay)
        else:
            fail(f"{artifact['id']}: download failed after {MAX_ATTEMPTS} attempts: {error}; leaving .part")


def verify_only(artifacts: list[dict[str, Any]], paths: dict[str, tuple[Path, Path]]) -> int:
    all_valid = True
    for artifact in artifacts:
        final_path, _ = paths[artifact["id"]]
        valid = inspect_final(artifact, final_path, print_result=True)
        if artifact.get("required", True) and not valid:
            all_valid = False
    return 0 if all_valid else 1


def main() -> int:
    args = parse_args()
    artifacts = selected_artifacts(load_manifest(args.manifest.expanduser().resolve()), args.model)
    if not artifacts:
        fail(f"no artifacts found for --model {args.model}")
    checkout = ensure_checkout(args.comfyui_dir)
    paths = check_final_conflicts(artifacts, checkout)
    if args.verify_only:
        return verify_only(artifacts, paths)
    planned_bytes, resolved_sizes = plan_downloads(artifacts, checkout, paths, allow_network=not args.dry_run)
    print_disk_plan(checkout, planned_bytes)
    if args.dry_run:
        print("Dry run complete; no files were downloaded or changed.")
        return 0
    for artifact in artifacts:
        final_path, part_path = paths[artifact["id"]]
        if final_path.is_file():
            continue
        download_artifact(artifact, final_path, part_path, resolved_sizes.get(artifact["id"]))
    print("All requested model artifacts are installed and verified.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ModelError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
