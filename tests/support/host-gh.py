#!/usr/bin/env python3
"""Host-side stand-in for the gh commands this repository's scripts invoke.

Release bytes live in GITHUB_RELEASE_DB/<tag>/<filename>, the same layout
tests/support/container-gh.sh writes. The token value is never printed.
"""

import hashlib
import json
import os
import shutil
import sys
from pathlib import Path


def db_root() -> Path:
    raw = os.environ.get("GITHUB_RELEASE_DB", "")
    if not raw:
        sys.stderr.write("gh: GITHUB_RELEASE_DB is not set\n")
        sys.exit(1)
    return Path(raw)


def require_token() -> None:
    if not os.environ.get("GH_TOKEN"):
        sys.stderr.write("gh: GH_TOKEN is not set\n")
        sys.exit(1)


def tag_dir(tag: str) -> Path:
    return db_root() / tag


def assets_of(tag: str) -> list[dict]:
    directory = tag_dir(tag)
    found = []
    if not directory.is_dir():
        return found
    for path in sorted(directory.iterdir()):
        if not path.is_file() or path.name.startswith("."):
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        found.append({"name": path.name, "digest": f"sha256:{digest}"})
    return found


def take_option_value(args: list[str], index: int) -> int:
    if index + 1 < len(args):
        return index + 1
    return index


def parse_tag_and_files(args: list[str]) -> tuple[str, list[str]]:
    tag = ""
    files: list[str] = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in {"--title", "--notes", "--target", "-R", "--repo", "--pattern", "-D", "--dir", "-q", "--jq", "--json"}:
            index = take_option_value(args, index) + 1
            continue
        if arg.startswith("--"):
            index += 1
            continue
        if not tag:
            tag = arg
        else:
            files.append(arg)
        index += 1
    return tag, files


def option_map(args: list[str]) -> dict[str, str]:
    found: dict[str, str] = {}
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in {"-R", "--repo", "--pattern", "-D", "--dir", "-q", "--jq", "--json", "--title", "--notes"}:
            if index + 1 < len(args):
                found[arg] = args[index + 1]
                index += 2
                continue
        index += 1
    return found


def cmd_view(args: list[str]) -> None:
    options = option_map(args)
    tag, _files = parse_tag_and_files(args)
    if not tag or not tag_dir(tag).is_dir():
        sys.stderr.write("release not found\n")
        sys.exit(1)
    if "--json" in options:
        payload = {"tagName": tag, "assets": assets_of(tag)}
        sys.stdout.write(json.dumps(payload))
        return
    sys.stdout.write(tag + "\n")


def cmd_list(args: list[str]) -> None:
    root = db_root()
    tags = []
    if root.is_dir():
        tags = sorted(path.name for path in root.iterdir() if path.is_dir())
    options = option_map(args)
    if "--json" in options:
        query = options.get("-q", "")
        if "tagName" in query:
            sys.stdout.write("\n".join(tags))
            if tags:
                sys.stdout.write("\n")
            return
        sys.stdout.write(json.dumps([{"tagName": tag} for tag in tags]))
        return
    for tag in tags:
        sys.stdout.write(tag + "\n")


def cmd_download(args: list[str]) -> None:
    options = option_map(args)
    tag, _files = parse_tag_and_files(args)
    if not tag or not tag_dir(tag).is_dir():
        sys.stderr.write("release not found\n")
        sys.exit(1)
    pattern = options.get("--pattern", "*")
    dest = Path(options.get("-D") or options.get("--dir") or ".")
    dest.mkdir(parents=True, exist_ok=True)
    matched = False
    for asset in assets_of(tag):
        name = asset["name"]
        if not _match(pattern, name):
            continue
        shutil.copyfile(tag_dir(tag) / name, dest / name)
        matched = True
    if not matched:
        sys.exit(1)


def cmd_create(args: list[str]) -> None:
    require_token()
    tag, files = parse_tag_and_files(args)
    if not tag:
        sys.stderr.write("gh: tag required\n")
        sys.exit(1)
    dest = tag_dir(tag)
    dest.mkdir(parents=True, exist_ok=True)
    for file_name in files:
        source = Path(file_name)
        shutil.copyfile(source, dest / source.name)
    (dest / ".release").write_text("created\n", encoding="utf-8")


def cmd_upload(args: list[str]) -> None:
    require_token()
    tag, files = parse_tag_and_files(args)
    if not tag or not tag_dir(tag).is_dir():
        sys.stderr.write("release not found\n")
        sys.exit(1)
    dest = tag_dir(tag)
    for file_name in files:
        source = Path(file_name)
        shutil.copyfile(source, dest / source.name)


def _match(pattern: str, name: str) -> bool:
    if pattern == "*":
        return True
    if pattern.startswith("*."):
        return name.endswith(pattern[1:])
    return name == pattern


def main() -> None:
    args = sys.argv[1:]
    if not args or args[0] != "release":
        sys.stderr.write("gh: unsupported command\n")
        sys.exit(1)
    verb = args[1] if len(args) > 1 else ""
    rest = args[2:]
    if verb == "view":
        cmd_view(rest)
    elif verb == "list":
        cmd_list(rest)
    elif verb == "download":
        cmd_download(rest)
    elif verb == "create":
        cmd_create(rest)
    elif verb == "upload":
        cmd_upload(rest)
    else:
        sys.stderr.write("gh: unsupported release command\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
