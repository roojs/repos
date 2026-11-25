#!/usr/bin/env bash
# Supply-chain tests for parser packaging.
#
# The builder clones grammar repositories and runs `tree-sitter generate`,
# which loads grammar.js as a Node program. These tests fail while a grammar
# that is not pinned to a full commit SHA, or that is no longer the pinned
# commit, can run during a build. They pass once that execution is refused
# before any grammar file runs.
#
# Run from the repository root:
#   bash tests/unpinned-grammar-supply-chain.sh
#
# Required tools: php, node, npm, git, gcc, dpkg-buildpackage, tree-sitter
# 0.20.x (or network access so the builder can install tree-sitter-cli@0.20.8),
# and a linkable libtree-sitter.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export PATH

failures=0
passes=0

pass() {
  passes=$((passes + 1))
  printf 'PASS %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL %s\n' "$1"
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" | sed 's/^/  /'
  fi
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "precondition:$1" "required command '$1' is not on PATH"
    return 1
  fi
}

preflight() {
  local ok=0
  require_tool php || ok=1
  require_tool node || ok=1
  require_tool npm || ok=1
  require_tool git || ok=1
  require_tool gcc || ok=1
  require_tool dpkg-buildpackage || ok=1
  if ! echo 'int main(void){return 0;}' | gcc -x c - -ltree-sitter -o /tmp/ts-link-probe >/dev/null 2>&1; then
    fail "precondition:libtree-sitter" "gcc cannot link -ltree-sitter; install libtree-sitter-dev"
    ok=1
  fi
  rm -f /tmp/ts-link-probe
  return "$ok"
}

write_grammar() {
  local dir="$1"
  local label="$2"
  local nested="${3:-1}"
  mkdir -p "$dir"
  cat > "$dir/grammar.js" << EOF
const fs = require('fs');
fs.mkdirSync(process.env.MARKER_DIR, { recursive: true });
fs.writeFileSync(process.env.MARKER_DIR + '/${label}-root', 'ran\\n');
module.exports = grammar({
  name: 'payload',
  rules: { source_file: \$ => 'hello' },
});
EOF
  if [[ "$nested" == "1" ]]; then
    mkdir -p "$dir/nested"
    cat > "$dir/nested/grammar.js" << EOF
const fs = require('fs');
fs.mkdirSync(process.env.MARKER_DIR, { recursive: true });
fs.writeFileSync(process.env.MARKER_DIR + '/${label}-nested', 'ran\\n');
module.exports = grammar({
  name: 'payload_nested',
  rules: { source_file: \$ => 'hello' },
});
EOF
  fi
}

init_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -b main >/dev/null
  git -C "$dir" config user.email "grammar@example.com"
  git -C "$dir" config user.name "Grammar"
}

commit_grammar() {
  local dir="$1"
  local message="$2"
  git -C "$dir" add .
  git -C "$dir" commit -m "$message" >/dev/null
  git -C "$dir" rev-parse HEAD
}

parser_json() {
  local id="$1"
  local name="$2"
  local repo="$3"
  local extra="${4:-}"
  printf '    {"id": "%s", "name": "%s", "repo": "%s", "language": "%s"%s}' \
    "$id" "$name" "$repo" "$id" "$extra"
}

write_project() {
  local work="$1"
  local parsers_json="$2"
  mkdir -p "$work/repo/scripts" "$work/repo/config" "$work/base" "$work/out" "$work/home" "$work/bin"
  cp "$ROOT/scripts/tree-sitter-packages.php" "$work/repo/scripts/tree-sitter-packages.php"
  cat > "$work/repo/config/tree-sitter.json" << EOF
{
  "release_prefix": "tree-sitter-",
  "parsers": [
${parsers_json}
  ]
}
EOF
  cat > "$work/bin/rpm" << 'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$work/bin/rpm"
  cat > "$work/bin/git" << 'EOF'
#!/bin/sh
real=/usr/bin/git
if [ "${1:-}" = "clone" ] && [ -n "${TOCTOU_REMOTE:-}" ] && [ ! -f "${TOCTOU_FLAG:-}" ]; then
  "$real" "$@"
  status=$?
  if [ -n "${TOCTOU_FLAG:-}" ]; then
    : > "$TOCTOU_FLAG"
  fi
  "$real" --git-dir="${TOCTOU_REMOTE}/.git" update-ref refs/heads/main "$TOCTOU_BAD"
  exit "$status"
fi
exec "$real" "$@"
EOF
  chmod +x "$work/bin/git"
}

run_builder() {
  local work="$1"
  local mode="$2"
  local only="$3"
  local markers="$4"
  local toctou_remote="${5:-}"
  local toctou_bad="${6:-}"
  local -a args=()
  case "$mode" in
    deb) ;;
    rpm) args+=(--rpm) ;;
    suse) args+=(--suse) ;;
    *)
      fail "run_builder" "unknown mode $mode"
      return 1
      ;;
  esac
  if [[ -n "$only" ]]; then
    args+=("--only=${only}")
  fi
  local path="/usr/bin:/bin:/usr/sbin:/sbin"
  if [[ "$mode" != "deb" || -n "$toctou_remote" ]]; then
    path="$work/bin:${path}"
  fi
  local log="$work/build.log"
  local exit_code=0
  if [[ -n "$toctou_remote" ]]; then
    export TOCTOU_REMOTE="$toctou_remote"
    export TOCTOU_BAD="$toctou_bad"
    export TOCTOU_FLAG="$work/toctou-swapped"
  else
    unset TOCTOU_REMOTE TOCTOU_BAD TOCTOU_FLAG
  fi
  MARKER_DIR="$markers" \
    HOME="$work/home" \
    PATH="$path" \
    TREE_SITTER_BASE_DIR="$work/base" \
    TREE_SITTER_OUTPUT_DIR="$work/out" \
    php "$work/repo/scripts/tree-sitter-packages.php" "${args[@]}" >"$log" 2>&1 || exit_code=$?
  printf '%s' "$exit_code"
}

markers_present() {
  local dir="$1"
  shift
  local found=""
  local name
  for name in "$@"; do
    if [[ -e "$dir/$name" ]]; then
      found="${found}${name} "
    fi
  done
  printf '%s' "$found"
}

safe_directory_wildcard() {
  local home="$1"
  HOME="$home" git config --global --get-all safe.directory 2>/dev/null | grep -x '\*' || true
}

assert_refused() {
  local name="$1"
  local exit_code="$2"
  local markers="$3"
  shift 3
  local present
  present="$(markers_present "$markers" "$@")"
  local detail="exit=${exit_code}"
  if [[ -n "$present" ]]; then
    detail="${detail} markers=${present}"
  fi
  if [[ "$exit_code" -eq 0 || -n "$present" ]]; then
    fail "$name" "$detail"
  else
    pass "$name"
  fi
}

test_shipped_config_pins_full_shas() {
  local output
  output="$(php -r '
    $config = json_decode(file_get_contents($argv[1]), true);
    $bad = [];
    foreach ($config["parsers"] as $parser) {
      $commit = $parser["commit"] ?? "";
      if (!preg_match("/^[0-9a-f]{40}$/", $commit)) {
        $bad[] = $parser["id"] . " commit=" . ($commit === "" ? "<missing>" : $commit);
      }
    }
    if ($bad) {
      fwrite(STDERR, implode("\n", $bad) . "\n");
      exit(1);
    }
  ' "$ROOT/config/tree-sitter.json" 2>&1)" || {
    fail "shipped_config_pins_every_parser_to_full_sha" "$output"
    return
  }
  pass "shipped_config_pins_every_parser_to_full_sha"
}

test_workflow_build_jobs_are_unprivileged() {
  local output
  output="$(php -r '
    $src = file_get_contents($argv[1]);
    $php = file_get_contents($argv[2]);
    $errors = [];
    if (preg_match("/safe\\.directory[\\s\\S]{0,120}\\*/", $src)) {
      $errors[] = "workflow sets git safe.directory wildcard";
    }
    if (preg_match("/safe\\.directory[\\s\\S]{0,120}\\*/", $php)) {
      $errors[] = "tree-sitter-packages.php sets git safe.directory wildcard";
    }
    $lines = preg_split("/\\n/", $src);
    $workflowPerm = "";
    $jobsStart = null;
    foreach ($lines as $i => $line) {
      if ($line === "jobs:") {
        $jobsStart = $i;
        break;
      }
    }
    if ($jobsStart === null) {
      $errors[] = "workflow has no jobs";
      fwrite(STDERR, implode("\n", $errors) . "\n");
      exit(1);
    }
    for ($i = 0; $i < $jobsStart; $i++) {
      if (preg_match("/^  contents:\\s*(\\S+)/", $lines[$i], $m)) {
        $workflowPerm = $m[1];
      }
    }
    $jobs = [];
    $current = null;
    for ($i = $jobsStart + 1; $i < count($lines); $i++) {
      if (preg_match("/^  ([A-Za-z0-9_-]+):\\s*$/", $lines[$i], $m)) {
        $current = $m[1];
        $jobs[$current] = [];
        continue;
      }
      if ($current !== null) {
        $jobs[$current][] = $lines[$i];
      }
    }
    $sawBuilder = false;
    foreach ($jobs as $name => $bodyLines) {
      $body = implode("\n", $bodyLines);
      if (strpos($body, "tree-sitter-packages.php") === false) {
        continue;
      }
      $sawBuilder = true;
      $jobPerm = "";
      $inPerm = false;
      foreach ($bodyLines as $line) {
        if (preg_match("/^    steps:\\s*$/", $line)) {
          break;
        }
        if (preg_match("/^    permissions:\\s*$/", $line)) {
          $inPerm = true;
          continue;
        }
        if ($inPerm && preg_match("/^    [A-Za-z]/", $line)) {
          $inPerm = false;
        }
        if ($inPerm && preg_match("/contents:\\s*(\\S+)/", $line, $m)) {
          $jobPerm = $m[1];
        }
      }
      $effective = $jobPerm !== "" ? $jobPerm : $workflowPerm;
      if ($effective !== "read") {
        $errors[] = "job {$name} effective contents permission is " . ($effective === "" ? "<default>" : $effective);
      }
      $steps = preg_split("/\\n      - /", "\n" . $body);
      $sawCheckout = false;
      foreach ($steps as $step) {
        if (strpos($step, "actions/checkout@") === false) {
          continue;
        }
        $sawCheckout = true;
        if (strpos($step, "persist-credentials: false") === false) {
          $errors[] = "job {$name} checkout persists credentials";
        }
      }
      if (!$sawCheckout) {
        $errors[] = "job {$name} does not checkout with persist-credentials disabled";
      }
    }
    if (!$sawBuilder) {
      $errors[] = "no job runs tree-sitter-packages.php";
    }
    if ($errors) {
      fwrite(STDERR, implode("\n", $errors) . "\n");
      exit(1);
    }
  ' "$ROOT/.github/workflows/build-tree-sitter.yml" "$ROOT/scripts/tree-sitter-packages.php" 2>&1)" || {
    fail "workflow_grammar_job_cannot_push_or_widen_git" "$output"
    return
  }
  pass "workflow_grammar_job_cannot_push_or_widen_git"
}

test_unpinned_ids_do_not_execute() {
  local mode="$1"
  local id
  for id in vala markdown rpmspec; do
    local tmp markers work exit_code present_detail
    tmp="$(mktemp -d)"
    markers="$(mktemp -d)"
    init_repo "$tmp/grammar"
    write_grammar "$tmp/grammar" "$id"
    commit_grammar "$tmp/grammar" "unpinned" >/dev/null
    work="$(mktemp -d)"
    write_project "$work" "$(parser_json "$id" "tree-sitter-${id}" "$tmp/grammar")"
    exit_code="$(run_builder "$work" "$mode" "$id" "$markers")"
    assert_refused "unpinned_${mode}_${id}_does_not_execute_grammar" "$exit_code" "$markers" \
      "${id}-root" "${id}-nested"
    if [[ -n "$(safe_directory_wildcard "$work/home")" ]]; then
      fail "unpinned_${mode}_${id}_does_not_set_safe_directory_wildcard" "git safe.directory contains *"
    else
      pass "unpinned_${mode}_${id}_does_not_set_safe_directory_wildcard"
    fi
    rm -rf "$tmp" "$markers" "$work"
  done
}

test_subdirectory_grammar_does_not_execute() {
  local tmp markers work exit_code
  tmp="$(mktemp -d)"
  markers="$(mktemp -d)"
  init_repo "$tmp/grammar"
  mkdir -p "$tmp/grammar/tree-sitter-markdown"
  cat > "$tmp/grammar/tree-sitter-markdown/grammar.js" << 'EOF'
const fs = require('fs');
fs.mkdirSync(process.env.MARKER_DIR, { recursive: true });
fs.writeFileSync(process.env.MARKER_DIR + '/subdir-only', 'ran\n');
module.exports = grammar({
  name: 'payload_nested',
  rules: { source_file: $ => 'hello' },
});
EOF
  commit_grammar "$tmp/grammar" "nested only" >/dev/null
  work="$(mktemp -d)"
  write_project "$work" "$(parser_json "markdown" "tree-sitter-markdown" "$tmp/grammar")"
  exit_code="$(run_builder "$work" "deb" "markdown" "$markers")"
  assert_refused "unpinned_subdirectory_grammar_does_not_execute" "$exit_code" "$markers" "subdir-only"
  rm -rf "$tmp" "$markers" "$work"
}

test_version_tag_does_not_execute() {
  local tmp markers work exit_code sha
  tmp="$(mktemp -d)"
  markers="$(mktemp -d)"
  init_repo "$tmp/grammar"
  write_grammar "$tmp/grammar" "tag"
  sha="$(commit_grammar "$tmp/grammar" "tagged payload")"
  git -C "$tmp/grammar" tag "v0.20.4" "$sha"
  work="$(mktemp -d)"
  write_project "$work" "$(parser_json "rust" "tree-sitter-rust" "$tmp/grammar" ', "tag": "0.20.4"')"
  exit_code="$(run_builder "$work" "deb" "rust" "$markers")"
  assert_refused "version_tag_pin_does_not_execute_grammar" "$exit_code" "$markers" "tag-root" "tag-nested"
  rm -rf "$tmp" "$markers" "$work"
}

test_sha_pin_rejects_other_branch() {
  local tmp markers work exit_code good bad
  tmp="$(mktemp -d)"
  markers="$(mktemp -d)"
  init_repo "$tmp/grammar"
  write_grammar "$tmp/grammar" "good"
  good="$(commit_grammar "$tmp/grammar" "good")"
  write_grammar "$tmp/grammar" "bad"
  bad="$(commit_grammar "$tmp/grammar" "bad")"
  work="$(mktemp -d)"
  write_project "$work" "$(parser_json "vala" "tree-sitter-vala" "$tmp/grammar" ", \"commit\": \"${good}\"")"
  exit_code="$(run_builder "$work" "deb" "vala" "$markers")"
  assert_refused "full_sha_pin_does_not_execute_moved_branch" "$exit_code" "$markers" \
    "bad-root" "bad-nested" "good-root" "good-nested"
  if [[ "$bad" == "$good" ]]; then
    fail "full_sha_pin_does_not_execute_moved_branch" "fixture commits were identical"
  fi
  rm -rf "$tmp" "$markers" "$work"
}

test_sha_checked_out_is_the_sha_that_runs() {
  local tmp markers work exit_code good
  tmp="$(mktemp -d)"
  markers="$(mktemp -d)"
  init_repo "$tmp/grammar"
  write_grammar "$tmp/grammar" "pinned"
  good="$(commit_grammar "$tmp/grammar" "pinned")"
  work="$(mktemp -d)"
  write_project "$work" "$(parser_json "vala" "tree-sitter-vala" "$tmp/grammar" ", \"commit\": \"${good}\"")"
  exit_code="$(run_builder "$work" "deb" "vala" "$markers")"
  local present
  present="$(markers_present "$markers" "pinned-root" "pinned-nested")"
  if [[ "$exit_code" -eq 0 && "$present" == "pinned-root pinned-nested " ]]; then
    pass "matching_full_sha_builds_that_commit"
  else
    fail "matching_full_sha_builds_that_commit" "exit=${exit_code} markers=${present:-<none>}"
  fi
  rm -rf "$tmp" "$markers" "$work"
}

test_second_fetch_cannot_swap_grammar() {
  local tmp markers work exit_code good bad
  tmp="$(mktemp -d)"
  markers="$(mktemp -d)"
  init_repo "$tmp/grammar"
  write_grammar "$tmp/grammar" "good"
  good="$(commit_grammar "$tmp/grammar" "good")"
  write_grammar "$tmp/grammar" "bad"
  bad="$(commit_grammar "$tmp/grammar" "bad")"
  git -C "$tmp/grammar" branch attacker "$bad"
  git -C "$tmp/grammar" update-ref refs/heads/main "$good"
  work="$(mktemp -d)"
  write_project "$work" "$(parser_json "vala" "tree-sitter-vala" "$tmp/grammar" ", \"commit\": \"${good}\"")"
  exit_code="$(run_builder "$work" "deb" "vala" "$markers" "$tmp/grammar" "$bad")"
  local bad_present good_present
  bad_present="$(markers_present "$markers" "bad-root" "bad-nested")"
  good_present="$(markers_present "$markers" "good-root" "good-nested")"
  if [[ -n "$bad_present" ]]; then
    fail "fetch_between_pin_check_and_generate_does_not_run_new_grammar" \
      "exit=${exit_code} bad=${bad_present} good=${good_present:-<none>} swapped=$([[ -f "$work/toctou-swapped" ]] && echo yes || echo no)"
  elif [[ -z "$good_present" && "$exit_code" -eq 0 ]]; then
    fail "fetch_between_pin_check_and_generate_does_not_run_new_grammar" \
      "build succeeded without running the pinned grammar"
  else
    pass "fetch_between_pin_check_and_generate_does_not_run_new_grammar"
  fi
  rm -rf "$tmp" "$markers" "$work"
}

main() {
  preflight || {
    printf 'FAILED %s passed, %s failed\n' "$passes" "$failures"
    exit 1
  }
  test_shipped_config_pins_full_shas
  test_workflow_build_jobs_are_unprivileged
  test_unpinned_ids_do_not_execute deb
  test_unpinned_ids_do_not_execute rpm
  test_unpinned_ids_do_not_execute suse
  test_subdirectory_grammar_does_not_execute
  test_version_tag_does_not_execute
  test_sha_pin_rejects_other_branch
  test_second_fetch_cannot_swap_grammar
  test_sha_checked_out_is_the_sha_that_runs
  printf 'RESULT %s passed, %s failed\n' "$passes" "$failures"
  if [[ "$failures" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
