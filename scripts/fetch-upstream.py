#!/usr/bin/env python3
"""Download upstream release assets and record publish metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

from repo_config import (
    deb_suites_for_release,
    iter_projects,
    load_config,
    project_fetch_debs,
    project_fetch_rpms,
    project_repo,
)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def gh_json(args: list[str]) -> dict | None:
    result = subprocess.run(
        ["gh", *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def download_assets(owner: str, repo: str, pattern: str, dest: Path) -> bool:
    dest.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [
            "gh",
            "release",
            "download",
            "-R",
            f"{owner}/{repo}",
            "--pattern",
            pattern,
            "-D",
            str(dest),
            "--clobber",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--type", choices=["deb", "rpm"], required=True)
    parser.add_argument("--filter", default="")
    args = parser.parse_args()

    config = load_config(args.config)
    owner = config["owner"]
    repo_filter = [name for name in args.filter.split(",") if name.strip()] or None
    output = args.output
    output.mkdir(parents=True, exist_ok=True)

    index: dict[str, dict] = {}
    found = False

    for project in iter_projects(config, repo_filter):
        repo = project_repo(project)
        release = gh_json(["release", "view", "-R", f"{owner}/{repo}", "--json", "tagName"])
        if not release:
            print(f"Skipping {owner}/{repo}: no latest release.", file=sys.stderr)
            continue

        tag = release["tagName"]
        repo_dir = output / repo
        pattern = "*.deb" if args.type == "deb" else "*.rpm"

        if args.type == "deb":
            if not project_fetch_debs(project):
                continue
            suites = deb_suites_for_release(project, tag, config)
            if suites is None:
                print(
                    f"Skipping {owner}/{repo}@{tag}: no deb suite mapping in config.",
                    file=sys.stderr,
                )
                continue
        else:
            if not project_fetch_rpms(project):
                continue
            suites = None

        print(f"Downloading {pattern} from {owner}/{repo}@{tag} ...")
        if not download_assets(owner, repo, pattern, repo_dir):
            print(f"Skipping {owner}/{repo}@{tag}: no {args.type} assets.", file=sys.stderr)
            continue

        suffix = ".deb" if args.type == "deb" else ".rpm"
        packages: dict[str, dict] = {}
        for path in sorted(repo_dir.glob(f"*{suffix}")):
            if args.type == "rpm" and (
                "debuginfo" in path.name or "debugsource" in path.name
            ):
                path.unlink()
                print(f"Skipping {path.name}", file=sys.stderr)
                continue
            packages[path.name] = {
                "sha256": sha256_file(path),
            }
            if suites is not None:
                packages[path.name]["suites"] = suites

        if not packages:
            continue

        index[repo] = {"tag": tag, "packages": packages}
        found = True

    index_path = output / ".package-index.json"
    index_path.write_text(json.dumps(index, indent=2, sort_keys=True) + "\n")

    if not found:
        print(f"No {args.type} packages downloaded.", file=sys.stderr)
        return 1

    print(json.dumps(index, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
