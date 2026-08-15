#!/usr/bin/env python3
"""Generate reprepro conf/distributions from config/repos.json."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from repo_config import default_apt_suites, load_config


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    args = parser.parse_args()

    config = load_config(args.config)
    suites = default_apt_suites(config)
    architectures = config["apt"].get("architectures", ["amd64", "arm64"])

    blocks: list[str] = []
    for suite in suites:
        arch_list = " ".join(architectures)
        blocks.append(
            "\n".join(
                [
                    f"Codename: {suite}",
                    "Origin: roojs",
                    "Label: roojs",
                    f"Architectures: {arch_list}",
                    "Components: main",
                    "Description: Official APT repository for roojs packages",
                    "SignWith: default",
                    "",
                ]
            )
        )

    sys.stdout.write("\n".join(blocks).rstrip() + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
