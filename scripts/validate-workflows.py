#!/usr/bin/env python3
"""Perform static safety and manifest-name checks on checked-in ComfyUI workflows."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


CORE_NODE_TYPES = {
    "BetaSamplingScheduler",
    "CFGGuider",
    "CheckpointLoaderSimple",
    "CLIPLoader",
    "CLIPSetLastLayer",
    "CLIPTextEncode",
    "EmptyLatentImage",
    "EmptySD3LatentImage",
    "KSampler",
    "KSamplerSelect",
    "MarkdownNote",
    "ModelSamplingAuraFlow",
    "Note",
    "RandomNoise",
    "SaveImage",
    "SamplerCustomAdvanced",
    "T5TokenizerOptions",
    "UNETLoader",
    "VAEDecode",
    "VAELoader",
}
WORKFLOW_REQUIREMENTS = {
    "chroma1-hd-basic": (
        "Chroma1-HD.safetensors",
        "t5xxl_fp8_e4m3fn_scaled.safetensors",
        "ae.safetensors",
    ),
    "pony-v6-xl-basic": ("ponyDiffusionV6XL_v6StartWithThisOne.safetensors",),
}
WINDOWS_ABSOLUTE = re.compile(r"^[A-Za-z]:[\\/]|^\\\\|^//")


def collect_strings(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        result: list[str] = []
        for item in value:
            result.extend(collect_strings(item))
        return result
    if isinstance(value, dict):
        result = []
        for key, item in value.items():
            result.extend(collect_strings(key))
            result.extend(collect_strings(item))
        return result
    return []


def is_absolute_local_path(value: str) -> bool:
    return value.startswith("/") or value.startswith("\\") or bool(WINDOWS_ABSOLUTE.match(value))


def validate_workflow(path: Path) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{path.name}: invalid JSON: {exc}"], []
    if not isinstance(document, dict):
        errors.append(f"{path.name}: root must be a JSON object")
        return errors, warnings

    for value in collect_strings(document):
        if is_absolute_local_path(value):
            errors.append(f"{path.name}: absolute local path is not allowed: {value}")
        if value.lower().startswith(("http://", "https://")):
            errors.append(f"{path.name}: HTTP model/source URL is not allowed in a checked-in workflow: {value}")

    nodes = document.get("nodes")
    if not isinstance(nodes, list):
        errors.append(f"{path.name}: root.nodes must be an array")
        nodes = []
    for node in nodes:
        if not isinstance(node, dict):
            errors.append(f"{path.name}: node entry is not an object")
            continue
        node_type = node.get("type")
        if not isinstance(node_type, str) or not node_type:
            errors.append(f"{path.name}: node has no type")
            continue
        properties = node.get("properties")
        if isinstance(properties, dict) and properties.get("cnr_id") not in (None, "comfy-core"):
            errors.append(f"{path.name}: node {node_type} declares non-core package {properties.get('cnr_id')!r}")
        lowered = node_type.lower()
        if lowered.startswith("custom") or any(marker in lowered for marker in ("customnode", "lora", "controlnet", "manager")):
            errors.append(f"{path.name}: obvious custom/extension node is not allowed: {node_type}")
        elif node_type not in CORE_NODE_TYPES:
            warnings.append(f"{path.name}: node type is not in the validator's core-node allowlist: {node_type}")

    required_names = WORKFLOW_REQUIREMENTS.get(path.stem)
    if required_names:
        strings = set(collect_strings(document))
        for filename in required_names:
            if filename not in strings:
                errors.append(f"{path.name}: required canonical model filename is missing: {filename}")

    return errors, warnings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workflow-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "workflows",
    )
    args = parser.parse_args()
    workflow_dir = args.workflow_dir.expanduser().resolve()
    if not workflow_dir.is_dir():
        print(f"ERROR: workflow directory not found: {workflow_dir}", file=sys.stderr)
        return 1
    workflow_files = sorted(workflow_dir.glob("*.json"))
    if not workflow_files:
        print(f"ERROR: no workflow JSON files found in {workflow_dir}", file=sys.stderr)
        return 1

    all_errors: list[str] = []
    for path in workflow_files:
        errors, warnings = validate_workflow(path)
        for warning in warnings:
            print(f"WARNING: {warning}", file=sys.stderr)
        if errors:
            all_errors.extend(errors)
        else:
            print(f"VALID: {path.name}")
    for error in all_errors:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if all_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
