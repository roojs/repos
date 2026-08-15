#!/usr/bin/env python3
"""Load and query repository publish configuration."""

from __future__ import annotations

import fnmatch
import json
from pathlib import Path
from typing import Any


def load_config(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def project_repo(project: dict[str, Any]) -> str:
    return project["repo"]


def default_apt_suites(config: dict[str, Any]) -> list[str]:
    return list(config["apt"]["suites"])


def iter_projects(
    config: dict[str, Any],
    repo_filter: list[str] | None = None,
) -> list[dict[str, Any]]:
    projects = config["projects"]
    if not repo_filter:
        return projects
    allowed = {name.strip() for name in repo_filter if name.strip()}
    return [project for project in projects if project_repo(project) in allowed]


def project_fetch_debs(project: dict[str, Any]) -> bool:
    deb = project.get("deb")
    if deb is False:
        return False
    return True


def project_fetch_rpms(project: dict[str, Any]) -> bool:
    return bool(project.get("rpm"))


def deb_suites_for_release(
    project: dict[str, Any],
    tag: str,
    config: dict[str, Any],
) -> list[str] | None:
    deb = project.get("deb")
    if deb is False:
        return None

    if isinstance(deb, dict) and "release_tags" in deb:
        for pattern, suites in deb["release_tags"].items():
            if fnmatch.fnmatch(tag, pattern):
                return list(suites)
        return None

    if isinstance(deb, dict) and "suites" in deb:
        suites = deb["suites"]
        if suites == "default":
            return default_apt_suites(config)
        return list(suites)

    return default_apt_suites(config)
