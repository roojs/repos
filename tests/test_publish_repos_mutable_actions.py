"""Supply-chain tests for the package publish workflow.

They execute the publish job's third-party actions the way a scheduled run
does. A tag in an action repository is a git ref: moving it changes the
commit a later run checks out. A 40-character commit SHA does not move.

These tests fail while that tag move can observe the signing key, its
passphrase, or produce a signature with the key the job imported. They pass
once the publish workflow no longer gives a moved tag that capability.

Run:

    python3 -m unittest tests.test_publish_repos_mutable_actions

The tree-sitter workflow is not covered. It does not receive the signing key.
"""

import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "publish-repos.yml"

# Publish steps that do not delete the imported secret key. A replacement
# step, or one of these edited to delete the key, is executed.
KEYRING_PRESERVING_STEPS = {
    "Install fetch prerequisites",
    "Download upstream .deb release assets",
    "Download upstream .rpm release assets",
    "Require at least one package type",
    "Check for package changes",
    "Install reprepro dependencies",
    "Prune packages no longer in manifest",
    "Prune RPM packages no longer in manifest",
    "Check for manifest packages missing from repo",
    "Skip publish when unchanged",
    "Export repository signing key",
    "Sync reprepro config",
    "Drop vanished reprepro targets",
    "Ingest packages with reprepro",
    "Build DNF repositories",
    "Update publish manifest",
    "Clean up incoming packages",
    "Sync client setup files to Pages",
}

SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
EXPR_RE = re.compile(r"\$\{\{\s*([^}]+?)\s*\}\}")
NODE = shutil.which("node")

# Scheduled publish: packages were found and the manifest changed.
# inputs.force is null on schedule; it is only set for workflow_dispatch.
PUBLISH_CONTEXT = {
    "steps": {
        "fetch-debs": {"outputs": {"found": "true"}},
        "fetch-rpms": {"outputs": {"found": "true"}},
        "changes": {"outputs": {"changed": "true"}},
        "prune": {"outputs": {"pruned": "false"}},
        "rpm-prune": {"outputs": {"pruned": "false"}},
        "missing": {"outputs": {"missing": "false"}},
    },
    "inputs": {"force": None},
}


class WorkflowLoader(yaml.SafeLoader):
    pass


for _first, _resolvers in list(WorkflowLoader.yaml_implicit_resolvers.items()):
    WorkflowLoader.yaml_implicit_resolvers[_first] = [
        item for item in _resolvers if item[0] != "tag:yaml.org,2002:bool"
    ]


def load_workflow():
    return yaml.load(WORKFLOW.read_text(), Loader=WorkflowLoader)


def publish_steps():
    workflow = load_workflow()
    return workflow["jobs"]["publish"]["steps"]


BENIGN_ACTION = r"""
const {spawnSync} = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

function getInput(name) {
  const val = process.env[`INPUT_${name.replace(/ /g, '_').toUpperCase()}`] || '';
  return val.trim();
}

const key = getInput('gpg_private_key');
const passphrase = getInput('passphrase');
if (!key) process.exit(0);

const keyFolder = fs.mkdtempSync(path.join(os.tmpdir(), 'ghaction-import-gpg-'));
const keyPath = path.join(keyFolder, 'key.pgp');
fs.writeFileSync(keyPath, key, {mode: 0o600});
const imported = spawnSync('gpg', ['--import', '--batch', '--yes', keyPath], {encoding: 'utf8'});
fs.unlinkSync(keyPath);
if (imported.status !== 0) {
  process.stderr.write(imported.stderr || imported.stdout || 'gpg import failed');
  process.exit(imported.status || 1);
}

if (!passphrase) process.exit(0);

const home = process.env.GNUPGHOME;
fs.writeFileSync(
  path.join(home, 'gpg-agent.conf'),
  'default-cache-ttl 21600\nmax-cache-ttl 31536000\nallow-preset-passphrase\n'
);
const reloaded = spawnSync('gpg-connect-agent', ['RELOADAGENT', '/bye'], {encoding: 'utf8'});
if (reloaded.status !== 0) {
  process.stderr.write(reloaded.stderr || reloaded.stdout || 'reload agent failed');
  process.exit(reloaded.status || 1);
}
const listed = spawnSync(
  'gpg',
  ['--batch', '--with-colons', '--with-keygrip', '--list-secret-keys'],
  {encoding: 'utf8'}
);
const hex = Buffer.from(passphrase, 'utf8').toString('hex').toUpperCase();
for (const line of (listed.stdout || '').split(/\n/)) {
  if (!line.startsWith('grp:')) continue;
  const grip = line.split(':')[9];
  const preset = spawnSync(
    'gpg-connect-agent',
    [`PRESET_PASSPHRASE ${grip} -1 ${hex}`, '/bye'],
    {encoding: 'utf8'}
  );
  if (preset.status !== 0) {
    process.stderr.write(preset.stderr || preset.stdout || 'preset failed');
    process.exit(preset.status || 1);
  }
}
"""

ATTACKER_ACTION = r"""
const {spawnSync} = require('child_process');
const fs = require('fs');
const path = require('path');

const capture = process.env.PUBLISH_TEST_CAPTURE;
function note(line) {
  fs.appendFileSync(capture, line + '\n');
}
function getInput(name) {
  const val = process.env[`INPUT_${name.replace(/ /g, '_').toUpperCase()}`] || '';
  return val.trim();
}

const key = getInput('gpg_private_key');
const pass = getInput('passphrase');
if (key.includes('BEGIN PGP PRIVATE KEY BLOCK')) note('observed-private-key');
if (pass.length > 0) note('observed-passphrase');

const wrapDir = process.env.PUBLISH_TEST_WRAP_DIR;
const pathFile = process.env.GITHUB_PATH;
if (wrapDir && pathFile) {
  fs.mkdirSync(wrapDir, {recursive: true});
  const wrapper = path.join(wrapDir, 'gpg');
  if (!fs.existsSync(wrapper)) {
    const script = [
      '#!/bin/bash',
      'capture="$PUBLISH_TEST_CAPTURE"',
      'if [[ "${INPUT_GPG_PRIVATE_KEY:-}" == *"BEGIN PGP PRIVATE KEY BLOCK"* ]]; then',
      '  echo observed-private-key >> "$capture"',
      'fi',
      'if [[ -n "${INPUT_PASSPHRASE:-}" ]]; then',
      '  echo observed-passphrase >> "$capture"',
      'fi',
      'for arg in "$@"; do',
      '  if [[ -f "$arg" ]] && grep -q "BEGIN PGP PRIVATE KEY BLOCK" "$arg"; then',
      '    echo observed-private-key >> "$capture"',
      '  fi',
      'done',
      'exec /usr/bin/gpg "$@"',
      '',
    ].join('\n');
    fs.writeFileSync(wrapper, script, {mode: 0o755});
  }
  fs.appendFileSync(pathFile, wrapDir + '\n');
}

const msg = process.env.PUBLISH_TEST_SIGN_MSG;
const sig = process.env.PUBLISH_TEST_SIGN_OUT;
if (msg && sig) {
  spawnSync(
    'gpg',
    ['--batch', '--yes', '--pinentry-mode', 'loopback', '--detach-sign', '--armor', '-o', sig, msg],
    {encoding: 'utf8'}
  );
}
"""


def git(repo, *args, env=None):
    cmd_env = os.environ.copy()
    cmd_env.setdefault("GIT_AUTHOR_NAME", "publish-test")
    cmd_env.setdefault("GIT_AUTHOR_EMAIL", "publish-test@example.invalid")
    cmd_env.setdefault("GIT_COMMITTER_NAME", "publish-test")
    cmd_env.setdefault("GIT_COMMITTER_EMAIL", "publish-test@example.invalid")
    if env:
        cmd_env.update(env)
    subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        env=cmd_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


class ActionMirror:
    """Local action repository whose tags can be moved onto another commit."""

    def __init__(self, root: Path):
        self.root = root
        root.mkdir(parents=True)
        git(root, "init", "-q")
        self.benign = self._commit("benign.js", BENIGN_ACTION, "benign action")
        self.attacker = self._commit("attacker.js", ATTACKER_ACTION, "attacker action")
        # Keep the branch on the benign commit. Tags are moved per scenario.
        git(root, "checkout", "-q", "-B", "main", self.benign)

    def _commit(self, filename: str, source: str, message: str) -> str:
        for child in self.root.iterdir():
            if child.name == ".git":
                continue
            if child.is_file():
                child.unlink()
        script = textwrap.dedent(source).lstrip("\n")
        (self.root / "main.js").write_text(script)
        (self.root / "action.yml").write_text(
            "name: test-action\nruns:\n  using: node20\n  main: main.js\n"
        )
        git(self.root, "add", "main.js", "action.yml")
        git(self.root, "commit", "-q", "-m", message)
        return subprocess.check_output(
            ["git", "-C", str(self.root), "rev-parse", "HEAD"], text=True
        ).strip()

    def point_tag(self, tag: str, sha: str):
        # Same update an attacker with push access to the action repo performs.
        git(self.root, "update-ref", f"refs/tags/{tag}", sha)

    def resolve(self, ref: str) -> str:
        if SHA_RE.fullmatch(ref):
            return self.benign
        for candidate in (f"refs/tags/{ref}", f"refs/heads/{ref}"):
            result = subprocess.run(
                ["git", "-C", str(self.root), "rev-parse", "--verify", "-q", candidate],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            if result.returncode == 0:
                return result.stdout.strip()
        raise AssertionError(f"action ref {ref!r} did not resolve")

    def main_js(self, sha: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(self.root), "show", f"{sha}:main.js"], text=True
        )


def substitute_secrets(value, secrets):
    if value is None:
        return ""
    text = value if isinstance(value, str) else str(value)

    def repl(match):
        expr = match.group(1).strip()
        if expr.startswith("secrets."):
            return secrets[expr.split(".", 1)[1]]
        return match.group(0)

    return EXPR_RE.sub(repl, text)


def kind_of(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "num"
    if isinstance(value, str):
        return "str"
    return "obj"


def to_number(value):
    if value is None:
        return 0.0
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return float("nan")
    return float("nan")


def coerce(left, right):
    left_kind = kind_of(left)
    right_kind = kind_of(right)
    if left_kind == right_kind:
        return left, right
    if left_kind == "num" and right_kind == "str":
        return left, to_number(right)
    if left_kind == "str" and right_kind == "num":
        return to_number(left), right
    if left_kind in ("bool", "null"):
        return coerce(to_number(left), right)
    if right_kind in ("bool", "null"):
        return coerce(left, to_number(right))
    return left, right


def abstract_equal(left, right):
    left, right = coerce(left, right)
    if kind_of(left) != kind_of(right):
        return False
    current = kind_of(left)
    if current == "null":
        return True
    if current == "num":
        if left != left or right != right:
            return False
        return left == right
    if current == "str":
        return left.lower() == right.lower()
    if current == "bool":
        return left is right
    return left is right


class ExprParser:
    """The comparisons and && / || used by this workflow's step ifs."""

    def __init__(self, text, context):
        self.text = text
        self.length = len(text)
        self.index = 0
        self.context = context

    def parse(self):
        value = self._parse_or()
        self._skip()
        if self.index != self.length:
            raise ValueError(f"unparsed if expression: {self.text[self.index:]!r}")
        return bool(value)

    def _parse_or(self):
        value = self._parse_and()
        while self._consume("||"):
            rhs = self._parse_and()
            value = bool(value) or bool(rhs)
        return value

    def _parse_and(self):
        value = self._parse_eq()
        while self._consume("&&"):
            rhs = self._parse_eq()
            value = bool(value) and bool(rhs)
        return value

    def _parse_eq(self):
        value = self._parse_unary()
        while True:
            if self._consume("=="):
                value = abstract_equal(value, self._parse_unary())
            elif self._consume("!="):
                value = not abstract_equal(value, self._parse_unary())
            else:
                return value

    def _parse_unary(self):
        if self._consume("!"):
            return not bool(self._parse_unary())
        return self._parse_primary()

    def _parse_primary(self):
        self._skip()
        if self._consume("("):
            value = self._parse_or()
            if not self._consume(")"):
                raise ValueError("missing )")
            return value
        if self.text.startswith(("'", '"'), self.index):
            return self._parse_string()
        token = self._parse_token()
        if token == "true":
            return True
        if token == "false":
            return False
        if token == "null":
            return None
        if token[:1].isdigit():
            return float(token)
        current = self.context
        for part in token.split("."):
            if not isinstance(current, dict) or part not in current:
                return None
            current = current[part]
        return current

    def _parse_string(self):
        quote = self.text[self.index]
        self.index += 1
        chars = []
        while self.index < self.length and self.text[self.index] != quote:
            if self.text[self.index] == "\\":
                self.index += 1
            chars.append(self.text[self.index])
            self.index += 1
        self.index += 1
        return "".join(chars)

    def _parse_token(self):
        start = self.index
        while self.index < self.length and re.match(r"[A-Za-z0-9_.\-]", self.text[self.index]):
            self.index += 1
        if start == self.index:
            raise ValueError(f"bad token at {self.text[self.index:]!r}")
        return self.text[start:self.index]

    def _consume(self, op):
        self._skip()
        if self.text.startswith(op, self.index):
            self.index += len(op)
            return True
        return False

    def _skip(self):
        while self.index < self.length and self.text[self.index].isspace():
            self.index += 1


def condition_matches(step):
    expression = step.get("if")
    if expression is None:
        return True
    if isinstance(expression, bool):
        return expression
    return ExprParser(str(expression), PUBLISH_CONTEXT).parse()


def step_introduces_or_removes_key(step):
    blob = "\n".join(
        [
            str(step.get("run") or ""),
            str(step.get("env") or ""),
            str(step.get("with") or ""),
        ]
    )
    markers = (
        "APT_GPG_PRIVATE_KEY",
        "delete-secret-keys",
        "delete-keys",
        "KILLAGENT",
        "gpgconf",
    )
    return any(marker in blob for marker in markers)


def should_run_shell(step):
    if step.get("name") in KEYRING_PRESERVING_STEPS and not step_introduces_or_removes_key(step):
        return False
    return True


class PublishJob:
    def __init__(self, mirrors, secrets, root: Path):
        self.mirrors = mirrors
        self.secrets = secrets
        self.root = root
        self.gnupg = root / "gnupg"
        self.gnupg.mkdir(mode=0o700)
        os.chmod(self.gnupg, 0o700)
        self.capture = root / "capture.txt"
        self.capture.write_text("")
        self.wrap_dir = root / "gpg-wrap"
        self.sign_msg = root / "sign-me.txt"
        self.sign_msg.write_text("repository index\n")
        self.sign_out = root / "sign-me.txt.asc"
        self.prepend_path = []
        self.public_key = root / "public.asc"
        self.workspace = root / "workspace"
        main = self.workspace / "main"
        self.workspace.mkdir()
        main.symlink_to(REPO_ROOT)
        (self.workspace / "pages").mkdir()

    def run(self):
        for step in publish_steps():
            if not condition_matches(step):
                continue
            if "uses" in step:
                self._run_action(step)
            elif "run" in step and should_run_shell(step):
                self._run_shell(step)

    def _job_env(self, step_env):
        path = os.pathsep.join([*reversed(self.prepend_path), "/usr/bin", "/bin"])
        env = {
            "PATH": path,
            "HOME": str(self.root / "home"),
            "GNUPGHOME": str(self.gnupg),
            "PUBLISH_TEST_CAPTURE": str(self.capture),
            "PUBLISH_TEST_WRAP_DIR": str(self.wrap_dir),
            "PUBLISH_TEST_SIGN_MSG": str(self.sign_msg),
            "PUBLISH_TEST_SIGN_OUT": str(self.sign_out),
            "DEBIAN_FRONTEND": "noninteractive",
        }
        (self.root / "home").mkdir(exist_ok=True)
        env.update(step_env)
        return env

    def _run_action(self, step):
        uses = step["uses"]
        if uses.startswith("./"):
            return
        name, _, ref = uses.rpartition("@")
        if not ref:
            name, ref = uses, "main"
        mirror = self.mirrors[name]
        sha = mirror.resolve(ref)
        source = mirror.main_js(sha)
        script = self.root / "action-main.js"
        script.write_text(source)
        path_file = self.root / "github-path.txt"
        path_file.write_text("")
        inputs = {}
        for key, value in (step.get("with") or {}).items():
            inputs[f"INPUT_{str(key).replace(' ', '_').upper()}"] = substitute_secrets(
                value, self.secrets
            )
        env = self._job_env(inputs)
        env["GITHUB_PATH"] = str(path_file)
        result = subprocess.run(
            [NODE, str(script)],
            cwd=self.workspace,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"action {uses} exited {result.returncode}: {result.stderr[-500:]}"
            )
        for line in path_file.read_text().splitlines():
            if line and line not in self.prepend_path:
                self.prepend_path.append(line)

    def _run_shell(self, step):
        env_map = {}
        for key, value in (step.get("env") or {}).items():
            env_map[str(key)] = substitute_secrets(value, self.secrets)
        workdir = self.workspace
        if step.get("working-directory"):
            workdir = self.workspace / step["working-directory"]
        script = self.root / "step.sh"
        script.write_text(str(step["run"]))
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)],
            cwd=workdir,
            env=self._job_env(env_map),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"step {step.get('name')!r} exited {result.returncode}: {result.stderr[-500:]}"
            )

    def observed(self, marker: str) -> bool:
        return marker in self.capture.read_text()

    def signature_verifies(self) -> bool:
        if not self.sign_out.exists() or self.sign_out.stat().st_size == 0:
            return False
        verify_home = self.root / "verify-gnupg"
        if verify_home.exists():
            shutil.rmtree(verify_home)
        verify_home.mkdir(mode=0o700)
        os.chmod(verify_home, 0o700)
        exported = subprocess.run(
            ["gpg", "--batch", "--export", "--armor"],
            cwd=self.workspace,
            env=self._job_env({}),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if exported.returncode != 0 or not exported.stdout:
            return False
        self.public_key.write_bytes(exported.stdout)
        imported = subprocess.run(
            ["gpg", "--batch", "--import", str(self.public_key)],
            env={**self._job_env({}), "GNUPGHOME": str(verify_home)},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if imported.returncode != 0:
            return False
        verified = subprocess.run(
            ["gpg", "--batch", "--verify", str(self.sign_out), str(self.sign_msg)],
            env={**self._job_env({}), "GNUPGHOME": str(verify_home)},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return verified.returncode == 0

    def close(self):
        subprocess.run(
            ["gpgconf", "--kill", "gpg-agent"],
            env={**os.environ, "GNUPGHOME": str(self.gnupg)},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def generate_signing_material(directory: Path):
    gnupg = directory / "gen"
    gnupg.mkdir(mode=0o700)
    os.chmod(gnupg, 0o700)
    passphrase = "placeholder-passphrase"
    spec = directory / "key-spec"
    spec.write_text(
        "\n".join(
            [
                "Key-Type: RSA",
                "Key-Length: 2048",
                "Subkey-Type: RSA",
                "Subkey-Length: 2048",
                "Name-Real: Publish Test",
                "Name-Email: publish-test@example.invalid",
                "Expire-Date: 0",
                f"Passphrase: {passphrase}",
                "%commit",
                "",
            ]
        )
    )
    env = {**os.environ, "GNUPGHOME": str(gnupg)}
    subprocess.run(
        [
            "gpg",
            "--batch",
            "--pinentry-mode",
            "loopback",
            "--passphrase",
            passphrase,
            "--generate-key",
            str(spec),
        ],
        check=True,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    exported = subprocess.run(
        [
            "gpg",
            "--batch",
            "--pinentry-mode",
            "loopback",
            "--passphrase",
            passphrase,
            "--armor",
            "--export-secret-keys",
            "publish-test@example.invalid",
        ],
        check=True,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    subprocess.run(
        ["gpgconf", "--kill", "gpg-agent"],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    private_key = exported.stdout.decode()
    if "BEGIN PGP PRIVATE KEY BLOCK" not in private_key:
        raise AssertionError("generated signing key was not armored")
    return private_key, passphrase


class MutablePublishActionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._class_tmp = tempfile.TemporaryDirectory()
        root = Path(cls._class_tmp.name)
        material = root / "material"
        material.mkdir()
        cls.private_key, cls.passphrase = generate_signing_material(material)
        cls.secrets = {
            "APT_GPG_PRIVATE_KEY": cls.private_key,
            "APT_GPG_PASSPHRASE": cls.passphrase,
        }
        cls.mirrors = {
            "actions/checkout": ActionMirror(root / "checkout"),
            "crazy-max/ghaction-import-gpg": ActionMirror(root / "import-gpg"),
            "stefanzweifel/git-auto-commit-action": ActionMirror(root / "auto-commit"),
        }

    @classmethod
    def tearDownClass(cls):
        cls._class_tmp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def _point(self, moved):
        tags = {
            "actions/checkout": "v4",
            "crazy-max/ghaction-import-gpg": "v6",
            "stefanzweifel/git-auto-commit-action": "v5",
        }
        for name, tag in tags.items():
            mirror = self.mirrors[name]
            mirror.point_tag(tag, mirror.attacker if name in moved else mirror.benign)

    def _run(self, moved):
        self._point(moved)
        job = PublishJob(self.mirrors, self.secrets, Path(self.tmp.name))
        self.addCleanup(job.close)
        job.run()
        return job

    def test_scheduled_publish_runs_the_job_that_imports_the_key(self):
        workflow = load_workflow()
        schedule = workflow["on"]["schedule"]
        self.assertTrue(any(item.get("cron") for item in schedule))
        self.assertIn("main", workflow["on"]["push"]["branches"])
        self.assertIn("publish", workflow["jobs"])

    def test_moved_checkout_tag_cannot_read_the_signing_material(self):
        job = self._run({"actions/checkout"})
        self.assertFalse(
            job.observed("observed-private-key"),
            "moved actions/checkout tag read the signing private key",
        )
        self.assertFalse(
            job.observed("observed-passphrase"),
            "moved actions/checkout tag read the signing passphrase",
        )

    def test_moved_import_gpg_tag_cannot_read_the_signing_material(self):
        job = self._run({"crazy-max/ghaction-import-gpg"})
        self.assertFalse(
            job.observed("observed-private-key"),
            "moved ghaction-import-gpg tag read the signing private key",
        )
        self.assertFalse(
            job.observed("observed-passphrase"),
            "moved ghaction-import-gpg tag read the signing passphrase",
        )

    def test_moved_commit_action_cannot_sign_with_the_imported_key(self):
        job = self._run({"stefanzweifel/git-auto-commit-action"})
        self.assertFalse(
            job.signature_verifies(),
            "moved git-auto-commit-action tag signed with the key still in the job keyring",
        )

    def test_every_mutable_publish_action_is_covered(self):
        uncovered = []
        for step in publish_steps():
            uses = step.get("uses")
            if not uses or str(uses).startswith("./"):
                continue
            name, _, ref = str(uses).rpartition("@")
            if SHA_RE.fullmatch(ref or ""):
                continue
            if (name or uses) not in self.mirrors:
                uncovered.append(uses)
        self.assertEqual(uncovered, [])


if __name__ == "__main__":
    unittest.main()
