#!/usr/bin/env python3
"""Compare downloaded package index with the last published manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

from repo_config import load_config


def config_fingerprint(config_path: Path, distributions_path: Path | None) -> dict:
    payload = {
        "repos_json_sha256": hashlib.sha256(config_path.read_bytes()).hexdigest(),
    }
    if distributions_path and distributions_path.is_file():
        payload["distributions_sha256"] = hashlib.sha256(
            distributions_path.read_bytes()
        ).hexdigest()
    return payload


def read_index(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pages", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--distributions", type=Path, default=None)
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()

    manifest_path = args.pages / ".publish-manifest.json"
    current = {
        "debs": read_index(args.pages / "incoming-debs" / ".package-index.json"),
        "rpms": read_index(args.pages / "incoming-rpms" / ".package-index.json"),
        **config_fingerprint(args.config, args.distributions),
    }

    previous: dict = {}
    if manifest_path.is_file():
        previous = json.loads(manifest_path.read_text())

    changed = current != previous
    payload = json.dumps(current, indent=2, sort_keys=True) + "\n"

    if args.output:
        args.output.write_text(payload)

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
