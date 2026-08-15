#!/usr/bin/env python3
"""Compare downloaded packages with the last published manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path


def package_hashes(directory: Path, suffix: str) -> dict[str, str]:
    if not directory.is_dir():
        return {}
    result: dict[str, str] = {}
    for path in sorted(directory.glob(f"*{suffix}")):
        result[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def build_manifest(
    debs_dir: Path,
    rpms_dir: Path,
    distributions_file: Path | None,
) -> dict:
    manifest: dict = {
        "debs": package_hashes(debs_dir, ".deb"),
        "rpms": package_hashes(rpms_dir, ".rpm"),
    }
    if distributions_file and distributions_file.is_file():
        manifest["distributions_sha256"] = hashlib.sha256(
            distributions_file.read_bytes()
        ).hexdigest()
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pages", type=Path, required=True)
    parser.add_argument("--debs", type=Path, default=Path())
    parser.add_argument("--rpms", type=Path, default=Path())
    parser.add_argument("--distributions", type=Path, default=None)
    parser.add_argument("--write-manifest", action="store_true")
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()

    manifest_path = args.pages / ".publish-manifest.json"
    current = build_manifest(args.debs, args.rpms, args.distributions)

    previous: dict = {}
    if manifest_path.is_file():
        previous = json.loads(manifest_path.read_text())

    changed = current != previous

    payload = json.dumps(current, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(payload)
    if args.write_manifest:
        manifest_path.write_text(payload)
        print("Updated publish manifest.")
    else:
        if changed:
            print("Upstream packages or repository config changed.")
        else:
            print("No upstream package changes detected.")

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as handle:
            handle.write(f"changed={'true' if changed else 'false'}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
