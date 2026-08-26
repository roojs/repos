# roojs/repos

This repository publishes APT and DNF package repositories for [roojs](https://github.com/roojs) desktop projects.

For installation instructions, supported packages, and repository details, see:

**https://roojs.github.io/repos/**

## Clone

`gh-pages` is the published APT/DNF tree (`pool/`, `dists/`, `rpm/`) and is hundreds of megabytes. A default `git clone` fetches every branch, including that one.

```bash
git clone --single-branch git@github.com:roojs/repos.git
```

If this checkout already has `gh-pages`, stop fetching it and drop the remote-tracking ref:

```bash
git config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git fetch --prune origin
git gc --prune=now
```

## AI assistance

This repository was developed with the assistance of artificial intelligence.

- Requirements and direction were set by the author
- Workflow, reprepro configuration, and documentation were largely AI-generated
- The author has reviewed the overall approach and defaults, but not every line in detail
- Treat scripts and config as provisional until exercised in production
