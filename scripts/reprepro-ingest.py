#!/usr/bin/env python3
"""Ingest downloaded .deb files using per-project suite mappings."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--gpg-key-id", required=True)
    args = parser.parse_args()

    repo_root = args.repo_root
    incoming = repo_root / "incoming-debs"
    index_path = incoming / ".package-index.json"
    if not index_path.is_file():
        print("Missing incoming-debs/.package-index.json", file=sys.stderr)
        return 1

    index = json.loads(index_path.read_text())
    distributions = repo_root / "conf" / "distributions"
    text = distributions.read_text()
    text = text.replace("SignWith: default", f"SignWith: {args.gpg_key_id}")
    distributions.write_text(text)

    for repo, entry in index.items():
        tag = entry["tag"]
        for filename, meta in entry["packages"].items():
            deb = incoming / repo / filename
            if not deb.is_file():
                print(f"Missing {deb}", file=sys.stderr)
                return 1

            suites = meta.get("suites", [])
            if not suites:
                print(f"Skipping {filename}: no suites in package index.", file=sys.stderr)
                continue

            for suite in suites:
                result = subprocess.run(
                    ["reprepro", "-b", str(repo_root), "includedeb", suite, str(deb)],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if result.returncode == 0:
                    print(f"Added {filename} to {suite} ({repo}@{tag})")
                    continue

                combined = (result.stderr or "") + (result.stdout or "")
                if any(
                    phrase in combined.lower()
                    for phrase in (
                        "already exists",
                        "already there",
                        "already listed",
                        "already in pool",
                        "already registered",
                    )
                ):
                    print(f"Already published: {filename} ({suite})")
                    continue

                sys.stderr.write(combined)
                return result.returncode or 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
