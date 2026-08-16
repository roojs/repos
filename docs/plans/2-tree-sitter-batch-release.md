# 2. Tree-sitter batch release

Status: proposed

Checklist: `docs/guide-to-writing-plans.md`

## Purpose

- 🔷 Build the OLLMchat tree-sitter parser debs as release items on this project.
- 🔷 One batch. One release. All tree-sitter items together.
- 🔷 Date the release when it is cut.
- 🔷 Explore pins. Some grammars did not build on later versions.
- 🔷 `config/tree-sitter.json` holds the parser list and pin information.
- 🔷 Some parsers may be unpinned.
- 🔷 Many of these repos do not do GitHub Releases. They dump to GitHub. Do not rely on releases to monitor unpinned parsers.
- 🔷 Unpinned: track `main` or `master` (whichever the repo uses).
- 🔷 When a build fails, pin that parser and deal with it then.
- 🔷 The existing PHP script fetches and builds. Use that.
- 🔷 Not a long build. Caching checkouts is fine.
- ℹ️ Script: `/home/alan/gitlive/OLLMchat/docs/tools/tree-sitter-packages.php`
- 🔷 ⏳ Copy the script here, drive it from that JSON, cut a dated release, ingest it.

## Current behaviour

- ℹ️ Manual run of the PHP script. Clones into `~/git/<name>`. Builds `.deb`s. Optional `--install`.
- ℹ️ For `github.com/tree-sitter/*` it already checks out the highest tag ≤ host `tree-sitter --version`.
- ℹ️ Existing local debs (starting pins to explore):
  - `libtree-sitter-vala` 0.20.8
  - `libtree-sitter-bash` 0.20.5
  - `libtree-sitter-cpp` 0.20.5
  - `libtree-sitter-javascript` 0.20.4
  - `libtree-sitter-python` 0.20.4
  - `libtree-sitter-rust` 0.20.4
  - `libtree-sitter-java` 0.20.2
  - `libtree-sitter-ruby` 0.20.1
  - `libtree-sitter-c-sharp` 0.20.0
  - `libtree-sitter-go` 0.20.0
  - `libtree-sitter-php` 0.20.0
- ℹ️ Script comment on `go`: “stuff that fails”.
- ℹ️ `.so` name `tree_sitter_parser_<lang>.so` (what OLLMchat `TreeBase` loads first).
- ℹ️ Packages are amd64 only today.

## Pins

- 🔷 `tag` in `config/tree-sitter.json` is optional.
- 🔷 Set `tag` when we know a later tree does not build (or after CI fails).
- 🔷 Omit `tag` (or leave it empty) to follow `main` / `master`.
- 🔷 Do not watch GitHub Releases for unpinned parsers. A lot of them have none.
- 💩 ⏳ Starting `tag` values can be the local deb versions above, for parsers that already failed on later trees. The rest can start unpinned.
- 🔷 ⏳ Cache checkouts between runs.

## Script

- 🔷 Copy the PHP builder into this repo.
- 🔷 Drive the parser list and pins from `config/tree-sitter.json`.

### 1. Copy `scripts/tree-sitter-packages.php`

Why: 🔷 the PHP script is the builder.

Where: new file. Source is the ℹ️ path in Purpose.

Depends on: none.

#### Add — copy the OLLMchat file to `scripts/tree-sitter-packages.php`

No in-tree Remove. Copy, then apply §2.

### 2. `config/tree-sitter.json` — parser list and pins

Why: 🔷 JSON config with pin information. Some entries unpinned.

Where: new file.

Depends on: §1.

#### Add — new `config/tree-sitter.json`

```json
{
  "release_prefix": "tree-sitter-",
  "parsers": [
    {
      "id": "vala",
      "name": "tree-sitter-vala",
      "repo": "https://github.com/vala-lang/tree-sitter-vala",
      "language": "vala",
      "tag": "0.20.8"
    },
    {
      "id": "rust",
      "name": "tree-sitter-rust",
      "repo": "https://github.com/tree-sitter/tree-sitter-rust",
      "language": "rust",
      "tag": "0.20.4"
    },
    {
      "id": "python",
      "name": "tree-sitter-python",
      "repo": "https://github.com/tree-sitter/tree-sitter-python",
      "language": "python",
      "tag": "0.20.4"
    },
    {
      "id": "javascript",
      "name": "tree-sitter-javascript",
      "repo": "https://github.com/tree-sitter/tree-sitter-javascript",
      "language": "javascript",
      "tag": "0.20.4"
    },
    {
      "id": "java",
      "name": "tree-sitter-java",
      "repo": "https://github.com/tree-sitter/tree-sitter-java",
      "language": "java",
      "tag": "0.20.2"
    },
    {
      "id": "cpp",
      "name": "tree-sitter-cpp",
      "repo": "https://github.com/tree-sitter/tree-sitter-cpp",
      "language": "cpp",
      "tag": "0.20.5"
    },
    {
      "id": "c-sharp",
      "name": "tree-sitter-c-sharp",
      "repo": "https://github.com/tree-sitter/tree-sitter-c-sharp",
      "language": "c_sharp",
      "tag": "0.20.0"
    },
    {
      "id": "php",
      "name": "tree-sitter-php",
      "repo": "https://github.com/tree-sitter/tree-sitter-php",
      "language": "php",
      "tag": "0.20.0"
    },
    {
      "id": "ruby",
      "name": "tree-sitter-ruby",
      "repo": "https://github.com/tree-sitter/tree-sitter-ruby",
      "language": "ruby",
      "tag": "0.20.1"
    },
    {
      "id": "bash",
      "name": "tree-sitter-bash",
      "repo": "https://github.com/tree-sitter/tree-sitter-bash",
      "language": "bash",
      "tag": "0.20.5"
    },
    {
      "id": "markdown",
      "name": "tree-sitter-markdown",
      "repo": "https://github.com/tree-sitter-grammars/tree-sitter-markdown",
      "language": "markdown"
    },
    {
      "id": "go",
      "name": "tree-sitter-go",
      "repo": "https://github.com/tree-sitter/tree-sitter-go",
      "language": "go",
      "tag": "0.20.0"
    }
  ]
}
```

- 🔷 No `tag` means unpinned: checkout `main` or `master` after fetch.
- 💩 `go` starts pinned at 0.20.0 (script already marked it as failing). Drop the pin or the parser if the first CI run says otherwise.

### 3. `scripts/tree-sitter-packages.php` — load config, honour `tag`

Why: 🔷 honour optional `tag`. Unpinned stays on `main` / `master`.

Where: replace the in-file `$parsers` array. After clone/update, checkout `tag` when set, else default branch.

Depends on: §1, §2.

#### Replace with — `$parsers` assignment

Read `config/tree-sitter.json` from the repo root (script lives in `scripts/`).
Build `$this->parsers` from the `parsers` array.

```php
    private function loadParsers(): array
    {
        $configPath = dirname(__DIR__) . '/config/tree-sitter.json';
        $config = json_decode(file_get_contents($configPath), true);
        $parsers = [];
        foreach ($config['parsers'] as $parser) {
            $parsers[$parser['id']] = $parser;
        }
        return $parsers;
    }
```

- 💩 `loadParsers()` only if we cannot assign `$this->parsers` in the constructor from the same JSON. Prefer constructor assign if that is smaller.

#### Add — after clone/update, checkout `tag` or the default branch

Place after the existing clone-or-pull block, before `getTreeSitterVersion()` matching.
Skip the script’s “highest tag ≤ tree-sitter version” logic when config already decided.

```php
        if (!empty($parser['tag'])) {
            $this->executeCommand(
                "cd " . escapeshellarg($repoDir) . " && git fetch --tags && git checkout " . escapeshellarg($parser['tag']),
                true
            );
        } else {
            $this->executeCommand(
                "cd " . escapeshellarg($repoDir) . " && git fetch && git checkout main || git checkout master && git pull",
                true
            );
        }
```

- 🔷 A failed build is the signal to add a `tag` for that parser. Do not invent a release watcher.

## Release

- 🔷 One GitHub Release on `roojs/repos` with every parser `.deb` from that run.
- 🔷 Tag dated when released.

### 4. `.github/workflows/build-tree-sitter.yml` — batch build + release

Why: 🔷 build on this project as a batch.

Where: new workflow file.

Depends on: §1–§3.

#### Add — new `.github/workflows/build-tree-sitter.yml`

```yaml
name: Build tree-sitter packages

on:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Cache parser checkouts
        uses: actions/cache@v4
        with:
          path: cache/tree-sitter
          key: tree-sitter-checkouts-v1-${{ hashFiles('config/tree-sitter.json') }}
          restore-keys: |
            tree-sitter-checkouts-v1-

      - name: Install build dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
            git nodejs npm build-essential devscripts debhelper \
            libtree-sitter-dev tree-sitter-cli php-cli

      - name: Build packages
        run: php scripts/tree-sitter-packages.php
        env:
          TREE_SITTER_BASE_DIR: ${{ github.workspace }}/cache/tree-sitter

      - name: Publish dated release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          tag="tree-sitter-$(date -u +%Y-%m-%d)"
          gh release create "$tag" \
            cache/tree-sitter/libtree-sitter-*.deb \
            --title "$tag" \
            --notes "Tree-sitter parser batch ${tag}"
```

- 🔷 `workflow_dispatch`. Rebuild frequency is still open.
- 🔷 Cache path `cache/tree-sitter` (checkouts).
- 💩 Script must honour `TREE_SITTER_BASE_DIR` instead of `~/git`. One-line constructor change when copying.
- 💩 `ubuntu-24.04` so `libtree-sitter-dev` matches the 0.20.x pins.
- 💩 After release, `gh api` `repository_dispatch` `publish-repos` if we want ingest in the same motion.

## Ingest

- 🔷 These debs become repo packages like the other upstreams.

### 5. `config/repos.json` — fetch this repo’s tree-sitter release

Why: 🔷 batch release on this project is the upstream.

Where: `projects` array, end.

Depends on: §4.

#### Add — project entry for `roojs/repos` tree-sitter tags

```json
    {
      "repo": "repos",
      "deb": {
        "release_tags": {
          "tree-sitter-*": "default"
        }
      }
    }
```

- 💩 `fetch-upstream.sh` today uses `gh release view` (latest release). If that latest tag is `tree-sitter-*`, this works. If this repo grows other releases, fetch must pick the newest `tree-sitter-*` tag instead.

## LLM notes

- First batch can stay amd64. The PHP `debian/install` path is `usr/lib/x86_64-linux-gnu/`.
- Do not add a GitHub Release watcher for unpinned parsers.
- Do not add this build to the daily publish cron until rebuild frequency is approved.
