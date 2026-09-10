#!/usr/bin/env python3

import os
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERSION_PATTERN = r"\d+\.\d+\.\d+"


def fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def read_version(path: Path, pattern: str, label: str) -> str:
    match = re.search(pattern, path.read_text(encoding="utf-8"), re.MULTILINE)
    if match is None:
        fail(f"Could not find {label} in {path.relative_to(ROOT)}")
    return match.group(1)


pubspec_version = read_version(
    ROOT / "pubspec.yaml",
    rf"^version:\s*({VERSION_PATTERN}(?:\+\d+)?)\s*$",
    "pubspec version",
)
runtime_version = read_version(
    ROOT / "lib/foundation/app.dart",
    rf'final version = "({VERSION_PATTERN})";',
    "runtime app version",
)

pubspec_base_version = pubspec_version.split("+", maxsplit=1)[0]
if runtime_version != pubspec_base_version:
    fail(
        "Version mismatch: "
        f"pubspec.yaml={pubspec_version}, app.dart={runtime_version}"
    )

release_tag = os.environ.get("RELEASE_TAG", "").strip()
if release_tag:
    tag_version = release_tag.removeprefix("v").removeprefix("V")
    if tag_version != pubspec_base_version:
        fail(
            "Release tag mismatch: "
            f"tag={release_tag}, pubspec.yaml={pubspec_version}"
        )

release_suffix = f", release tag={release_tag}" if release_tag else ""
print(
    "Version consistency OK: "
    f"pubspec={pubspec_version}, runtime={runtime_version}{release_suffix}"
)
