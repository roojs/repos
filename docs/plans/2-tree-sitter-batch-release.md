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
- 🔷 Only build a parser when its source identity changed.
- 🔷 Pinned parsers: identity is the `tag`. Once built at that tag, never rebuild until the pin changes.
- 🔷 Unpinned parsers: identity is the default-branch HEAD. Rebuild only when HEAD moves.
- 🔷 Reuse `.deb`s from the latest `tree-sitter-*` release for unchanged parsers. Carry them into every new dated release.
- 🔷 Build on `ubuntu-24.04` as-is. Same environment for every run. No per-suite build variants.
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
- 🔷 A pinned `tag` is also the build identity. Same tag as last release means skip the build.
- 💩 ⏳ Starting `tag` values can be the local deb versions above, for parsers that already failed on later trees. The rest can start unpinned.
- 🔷 ⏳ Cache checkouts between runs.

## Incremental build

- 🔷 Each parser has a **source identity**:
  - Pinned: the `tag` string from config.
  - Unpinned: the `main` / `master` commit SHA after fetch.
- 🔷 Each parser has a **built identity** recorded in the latest `tree-sitter-*` release manifest.
- 🔷 Skip build when built identity equals source identity.
- 🔷 For pinned parsers this is almost always a skip after the first successful build.
- 🔷 Unpinned parsers rebuild only when upstream HEAD moves.
- 🔷 Unchanged `.deb`s are copied from the prior `tree-sitter-*` release, not rebuilt.
- 🔷 A new dated release always ships the full parser set: reused `.deb`s plus any freshly built ones.
- 🔷 One `ubuntu-24.04` build produces `.deb`s shared across all APT suites. No suite-specific rebuilds.

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

### 3b. `scripts/tree-sitter-packages.php` — skip unchanged parsers

Why: 🔷 only build when source identity changed. Reuse prior `.deb`s.

Where: per-parser build loop. Before clone/build.

Depends on: §2, §3.

#### Add — read prior manifest and skip when identity matches

The workflow passes `TREE_SITTER_MANIFEST` (path to manifest from the latest `tree-sitter-*` release) and `TREE_SITTER_OUTPUT_DIR` (where `.deb`s land for this run).

For each parser, resolve **source identity** after checkout:

- Pinned: `$parser['tag']`
- Unpinned: `git rev-parse HEAD` in the repo dir

Read the prior manifest (if present). Each entry is `{ "identity": "…", "deb": "libtree-sitter-…_….deb" }`.

When `identity` matches, copy the prior `.deb` into `TREE_SITTER_OUTPUT_DIR` and skip build for that parser.

```php
        $manifest = [];
        $manifestPath = getenv('TREE_SITTER_MANIFEST') ?: '';
        if ($manifestPath !== '' && is_readable($manifestPath)) {
            $manifest = json_decode(file_get_contents($manifestPath), true)['parsers'] ?? [];
        }
        $outputDir = getenv('TREE_SITTER_OUTPUT_DIR') ?: $this->baseDir;

        $identity = !empty($parser['tag'])
            ? $parser['tag']
            : trim(shell_exec('cd ' . escapeshellarg($repoDir) . ' && git rev-parse HEAD'));

        if (
            isset($manifest[$parser['id']])
            && ($manifest[$parser['id']]['identity'] ?? '') === $identity
            && is_readable($manifest[$parser['id']]['deb'])
        ) {
            copy($manifest[$parser['id']]['deb'], $outputDir . '/' . basename($manifest[$parser['id']]['deb']));
            continue;
        }
```

#### Add — write manifest after each successful build

Append to a run-local manifest (`$outputDir/tree-sitter-manifest.json`) so the release step can upload it:

```php
        $builtManifest['parsers'][$parser['id']] = [
            'identity' => $identity,
            'deb' => $outputDir . '/' . basename($debPath),
        ];
```

- 🔷 First run has no prior manifest. Every parser builds.
- 🔷 Pinned parsers on later runs almost always hit the skip path.

## Release

- 🔷 One GitHub Release on `roojs/repos` with every parser `.deb` from that run.
- 🔷 Tag dated when released.
- 🔷 Release includes `tree-sitter-manifest.json` so the next run can skip unchanged parsers.
- 🔷 Skip creating a release when every parser was reused and nothing changed.

### 4. `.github/workflows/build-tree-sitter.yml` — incremental batch build + release

Why: 🔷 build on this project as a batch. Reuse prior `.deb`s. Only rebuild what moved.

Where: new workflow file.

Depends on: §1–§3b.

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

      - name: Download prior release
        id: prior
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          mkdir -p cache/prior-release cache/output
          tag="$(gh release list --limit 50 --json tagName \
            --jq '[.[].tagName | select(startswith("tree-sitter-"))] | first // empty')"
          if [[ -z "$tag" ]]; then
            echo "has_prior=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          gh release download "$tag" --dir cache/prior-release
          echo "has_prior=true" >> "$GITHUB_OUTPUT"

      - name: Install build dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
            git nodejs npm build-essential devscripts debhelper \
            libtree-sitter-dev tree-sitter-cli php-cli jq

      - name: Build packages
        run: php scripts/tree-sitter-packages.php
        env:
          TREE_SITTER_BASE_DIR: ${{ github.workspace }}/cache/tree-sitter
          TREE_SITTER_OUTPUT_DIR: ${{ github.workspace }}/cache/output
          TREE_SITTER_MANIFEST: ${{ github.workspace }}/cache/prior-release/tree-sitter-manifest.json

      - name: Publish dated release
        if: steps.build.outputs.changed == 'true'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          tag="tree-sitter-$(date -u +%Y-%m-%d)"
          gh release create "$tag" \
            cache/output/libtree-sitter-*.deb \
            cache/output/tree-sitter-manifest.json \
            --title "$tag" \
            --notes "Tree-sitter parser batch ${tag}"
```

- 🔷 `workflow_dispatch`. Safe to run often — pinned parsers skip after first build.
- 🔷 Cache path `cache/tree-sitter` (checkouts). Output `.deb`s go in `cache/output`.
- 🔷 Prior release download seeds the skip manifest and supplies reused `.deb`s.
- 🔷 `ubuntu-24.04` is the only build image. No suite-specific variants.
- 💩 Script must honour `TREE_SITTER_BASE_DIR` instead of `~/git`. One-line constructor change when copying.
- 💩 `steps.build.outputs.changed` needs a small hook in the PHP script (or a wrapper) to set `changed=false` when every parser was reused.
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
- Pinned parsers: after the first successful build, every later run should skip them unless the `tag` in config changes.
- One `ubuntu-24.04` build serves all APT suites. Do not add per-suite rebuild logic.
