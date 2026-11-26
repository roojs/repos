#!/usr/bin/env bash
# Spec for the unpinned job-container finding in build-tree-sitter.yml.
#
# The test fails while a job container image is only a moving tag: a registry
# tag is republished, `docker pull` of that tag (the runner's pull) selects
# the replacement image, its /bin/sh runs the job's run steps, and the
# packages it writes are signed into the APT and DNF trees by the repository's
# own publish scripts.
#
# The test passes once every job container image is pinned to a sha256 digest.
# A moved tag is then not what `docker pull` runs.
#
# Run from the repository root:
#   bash tests/unpinned-container-supply-chain.test.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
support="${repo_root}/tests/support"
work="$(mktemp -d)"
registry_name="supply-chain-registry-$$"
containers=()

cleanup() {
  local cid
  for cid in "${containers[@]+"${containers[@]}"}"; do
    sudo docker rm -f "$cid" >/dev/null 2>&1 || true
  done
  sudo docker rm -f "$registry_name" >/dev/null 2>&1 || true
  sudo rm -rf "$work"
}
trap cleanup EXIT

die() {
  echo "HARNESS: $*" >&2
  exit 2
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing $1"
}

need python3
need jq
need gpg
need rpmbuild
need rpm2cpio
need dpkg-deb
need reprepro
need createrepo_c
need cpio
sudo docker info >/dev/null 2>&1 || die "docker is not available"

python3 - "$repo_root" "$work/jobs.json" <<'PY'
import json
import re
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
digest = re.compile(r"^.+@sha256:[0-9a-f]{64}$")
workflows = sorted((root / ".github" / "workflows").glob("*.yml"))
jobs = []
publish = {"schedule": False, "calls_fetch": False, "calls_rpm": False, "calls_reprepro": False}
release_script = ""
merge_script = ""
contents = ""

for path in workflows:
    data = yaml.safe_load(path.read_text())
    text = path.read_text()
    if path.name == "publish-repos.yml":
        on = data.get("on") or data.get(True) or {}
        publish["schedule"] = bool(on.get("schedule"))
        publish["calls_fetch"] = "scripts/fetch-upstream.sh" in text
        publish["calls_rpm"] = "scripts/build-rpm-repos.sh" in text
        publish["calls_reprepro"] = "scripts/reprepro-ingest.sh" in text
    permissions = data.get("permissions") or {}
    if path.name == "build-tree-sitter.yml":
        contents = str(permissions.get("contents") or "")
        for name, job in (data.get("jobs") or {}).items():
            if name == "release":
                for step in job.get("steps") or []:
                    if step.get("name") == "Merge manifest":
                        merge_script = step.get("run") or ""
                    if step.get("name") == "Publish dated release":
                        release_script = step.get("run") or ""
            container = job.get("container")
            image = None
            if isinstance(container, str):
                image = container
            elif isinstance(container, dict):
                image = container.get("image")
            if not image:
                continue
            steps = []
            for step in job.get("steps") or []:
                if "run" not in step:
                    continue
                env = {}
                for key, value in (step.get("env") or {}).items():
                    text_value = str(value)
                    text_value = text_value.replace("${{ github.workspace }}", "/__w/work")
                    text_value = text_value.replace("${{ github.repository }}", "roojs/repos")
                    text_value = text_value.replace("${{ github.token }}", "placeholder-token")
                    env[key] = text_value
                steps.append({"name": step.get("name") or "", "run": step["run"], "env": env})
            jobs.append(
                {
                    "workflow": path.name,
                    "job": name,
                    "image": str(image),
                    "pinned": bool(digest.match(str(image).strip())),
                    "steps": steps,
                }
            )

if not jobs:
    sys.stderr.write("no job containers found\n")
    sys.exit(2)
if not release_script or not merge_script:
    sys.stderr.write("release step scripts missing\n")
    sys.exit(2)
Path(sys.argv[2]).write_text(
    json.dumps(
        {
            "contents": contents,
            "jobs": jobs,
            "release_script": release_script,
            "merge_script": merge_script,
            "publish": publish,
        }
    ),
    encoding="utf-8",
)
PY

contents="$(jq -r '.contents' "$work/jobs.json")"
[[ "$contents" == "write" ]] || die "workflow permissions.contents is '$contents', expected the release token path"

jq -e '.publish.schedule and .publish.calls_fetch and .publish.calls_rpm and .publish.calls_reprepro' "$work/jobs.json" >/dev/null \
  || die "publish workflow no longer runs the fetch and signing scripts on a schedule"

mapfile -t unpinned < <(jq -r '.jobs[] | select(.pinned | not) | .job' "$work/jobs.json")

start_registry() {
  sudo docker rm -f "$registry_name" >/dev/null 2>&1 || true
  sudo docker run -d --name "$registry_name" -p 127.0.0.1:5000:5000 registry:2 >/dev/null
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS http://127.0.0.1:5000/v2/ >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.3
  done
  die "local registry did not start"
}

registry_ref_for() {
  local image="$1"
  printf '127.0.0.1:5000/%s\n' "$image"
}

# docker pull <image> is the runner command (actions/runner v2.338.2
# DockerCommandManager.DockerPull). A tag moves; a digest does not.
assert_digest_does_not_follow_tag() {
  local benign="$work/benign"
  local attacker="$work/attacker-pin"
  mkdir -p "$benign" "$attacker"
  printf 'FROM busybox:1.36.1\nRUN echo benign > /pin-identity\n' > "$benign/Dockerfile"
  printf 'FROM busybox:1.36.1\nRUN echo attacker > /pin-identity\n' > "$attacker/Dockerfile"
  sudo docker build -t 127.0.0.1:5000/pin-demo:1 "$benign" >/dev/null 2>&1
  sudo docker push 127.0.0.1:5000/pin-demo:1 >/dev/null
  local repo_digest benign_id
  repo_digest="$(sudo docker image inspect 127.0.0.1:5000/pin-demo:1 --format '{{index .RepoDigests 0}}')"
  [[ "$repo_digest" == *@sha256:* ]] || die "push did not yield a digest"
  benign_id="$(sudo docker image inspect 127.0.0.1:5000/pin-demo:1 --format '{{.Id}}')"
  sudo docker build -t 127.0.0.1:5000/pin-demo:1 "$attacker" >/dev/null 2>&1
  sudo docker push 127.0.0.1:5000/pin-demo:1 >/dev/null
  sudo docker rmi 127.0.0.1:5000/pin-demo:1 >/dev/null 2>&1 || true
  sudo docker pull 127.0.0.1:5000/pin-demo:1 >/dev/null
  local tag_id digest_id
  tag_id="$(sudo docker image inspect 127.0.0.1:5000/pin-demo:1 --format '{{.Id}}')"
  sudo docker pull "$repo_digest" >/dev/null
  digest_id="$(sudo docker image inspect "$repo_digest" --format '{{.Id}}')"
  [[ "$tag_id" != "$benign_id" ]] || die "docker pull of a moved tag did not change the image"
  [[ "$digest_id" == "$benign_id" ]] || die "docker pull of a digest followed the moved tag"
  echo "control: docker pull of a moved tag changed image id; docker pull of the digest did not"
}

build_rpm() {
  local name="$1" marker="$2" dest="$3"
  local top="$work/rpmbuild-$name"
  mkdir -p "$top"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
  cat > "$top/SPECS/$name.spec" <<EOF
Name: ${name}
Version: 1.0
Release: 1
Summary: parser package fixture
License: MIT
BuildArch: x86_64

%description
fixture

%install
mkdir -p %{buildroot}/usr/share/marker
printf '%s\n' '${marker}' > %{buildroot}/usr/share/marker/payload

%files
/usr/share/marker/payload
EOF
  rpmbuild --define "_topdir $top" -bb "$top/SPECS/$name.spec" >/dev/null 2>&1
  cp "$(find "$top/RPMS" -name '*.rpm' -print -quit)" "$dest"
}

build_deb() {
  local dest="$1"
  local root="$work/deb-root"
  rm -rf "$root"
  mkdir -p "$root/DEBIAN" "$root/usr/share/marker"
  cat > "$root/DEBIAN/control" <<'EOF'
Package: libtree-sitter-evil
Version: 9.9.9-1
Section: misc
Priority: optional
Architecture: amd64
Maintainer: Test <test@example.com>
Description: parser package fixture
EOF
  printf '%s\n' 'DEB_TOKEN_PAYLOAD' > "$root/usr/share/marker/payload"
  dpkg-deb --build "$root" "$dest" >/dev/null
}

build_attacker_image() {
  local ref="$1" rpm="$2" deb="$3"
  local context rpm_base deb_base
  rpm_base="$(basename "$rpm")"
  deb_base="$(basename "$deb")"
  context="$work/image-$(echo "$ref" | tr '/:' '__')"
  mkdir -p "$context"
  cp "$support/attack-sh.sh" "$context/attack-sh.sh"
  cp "$support/container-gh.sh" "$context/container-gh.sh"
  cp "$rpm" "$context/$rpm_base"
  cp "$deb" "$context/$deb_base"
  cat > "$context/Dockerfile" <<EOF
FROM busybox:1.36.1
COPY attack-sh.sh /bin/sh
COPY container-gh.sh /usr/bin/gh
COPY ${rpm_base} /opt/payload/${rpm_base}
COPY ${deb_base} /opt/payload/${deb_base}
RUN chmod 755 /bin/sh /usr/bin/gh
ENV PAYLOAD_RPM=/opt/payload/${rpm_base}
ENV PAYLOAD_DEB=/opt/payload/${deb_base}
EOF
  sudo docker build -t "$ref" "$context" >/dev/null 2>&1
}

run_container_job() {
  local job_json="$1" ref="$2" host_ws="$3" release_db="$4"
  local cid entry
  cid="$(sudo docker create \
    --workdir /__w/work \
    --entrypoint tail \
    -e GITHUB_ACTIONS=true \
    -e CI=true \
    -v "${host_ws}:/__w/work" \
    "$ref" \
    -f /dev/null)"
  containers+=("$cid")
  sudo docker start "$cid" >/dev/null
  entry="$(sudo docker inspect "$cid" --format '{{.Path}} {{json .Args}}')"
  [[ "$entry" == tail* ]] || die "job container entrypoint was not replaced with tail: $entry"
  if [[ -d "$release_db" ]]; then
    sudo docker exec "$cid" mkdir -p /var/lib/github-releases
    sudo docker cp "$release_db/." "$cid:/var/lib/github-releases"
  fi

  local count i
  count="$(jq '.steps | length' <<< "$job_json")"
  for ((i = 0; i < count; i++)); do
    local script env_file
    script="$work/step-$i.sh"
    jq -r --argjson i "$i" '.steps[$i].run' <<< "$job_json" > "$script"
    cp "$script" "$host_ws/step.sh"
    env_file="$work/step-$i.env"
    : > "$env_file"
    jq -r --argjson i "$i" '.steps[$i].env | to_entries[] | "\(.key)=\(.value)"' <<< "$job_json" >> "$env_file"
    printf '%s\n' "GITHUB_OUTPUT=/__w/work/step-output" >> "$env_file"
    : > "$host_ws/step-output"
    local -a docker_env=(sudo env)
    local line key
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      key="${line%%=*}"
      docker_env+=("${key}=${line#*=}")
    done < "$env_file"
    local -a pass=()
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      pass+=(-e "${line%%=*}")
    done < "$env_file"
    # The step script is a file argument. -i matches ContainerStepHost; stdin is
    # not the script, so it must not consume the caller's stream.
    "${docker_env[@]}" docker exec -i --workdir /__w/work "${pass[@]}" "$cid" sh -e /__w/work/step.sh </dev/null
  done

  sudo docker cp "$cid:/var/lib/github-releases/." "$release_db/" 2>/dev/null || true
  sudo chown -R "$(id -u):$(id -g)" "$host_ws" "$release_db"
}

publish_trees() {
  local release_db="$1" pages="$2"
  mkdir -p "$pages/incoming-debs" "$pages/incoming-rpms" "$pages/conf" "$work/bin" "$work/gnupg"
  chmod 700 "$work/gnupg"
  export GNUPGHOME="$work/gnupg"
  export GITHUB_RELEASE_DB="$release_db"
  export GH_TOKEN="placeholder-token"
  gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "Repo Test <repo-test@example.com>" rsa3072 sign never >/dev/null
  printf '%s\n' "allow-loopback-pinentry" > "$GNUPGHOME/gpg-agent.conf"
  printf '%s\n' "pinentry-mode loopback" > "$GNUPGHOME/gpg.conf"
  gpgconf --kill gpg-agent >/dev/null 2>&1 || true

  cat > "$work/bin/gh" <<EOF
#!/bin/sh
exec python3 "$support/host-gh.py" "\$@"
EOF
  chmod +x "$work/bin/gh"
  export PATH="$work/bin:$PATH"

  local ws="$work/workspace"
  mkdir -p "$ws/cache/output-deb"
  printf '%s\n' '{"parsers":{}}' > "$ws/cache/output-deb/tree-sitter-manifest.json"
  (
    cd "$ws"
    # Host release job: actions/runner v2.338.2 ScriptHandler runs bash -e
    # when bash is on PATH (fileName = commandPath, arguments = sh format).
    bash -e "$work/merge.sh"
    bash -e "$work/release.sh"
  )

  (
    cd "$repo_root"
    bash scripts/fetch-upstream.sh \
      config/repos.json \
      "$pages/incoming-debs" \
      deb \
      repos
    bash scripts/fetch-upstream.sh \
      config/repos.json \
      "$pages/incoming-rpms" \
      rpm \
      repos
  )

  bash "$repo_root/scripts/generate-distributions.sh" "$repo_root/config/repos.json" > "$pages/conf/distributions"
  local key_id
  key_id="$(gpg --list-secret-keys --keyid-format LONG | awk '/^sec/ {print $2}' | cut -d/ -f2 | head -n 1)"
  [[ -n "$key_id" ]] || die "no gpg key"
  (
    cd "$repo_root"
    bash scripts/reprepro-ingest.sh "$pages" "$key_id" config/repos.json
    bash scripts/build-rpm-repos.sh "$pages/incoming-rpms" "$pages"
  )
}

marker_in_tree() {
  local marker="$1" root="$2"
  local rpm deb
  shopt -s globstar nullglob
  for rpm in "$root"/rpm/**/*.rpm; do
    local extracted="$work/extract-rpm"
    rm -rf "$extracted"
    mkdir -p "$extracted"
    if (cd "$extracted" && rpm2cpio "$rpm" | cpio -idmu --quiet) && grep -R -q -F "$marker" "$extracted"; then
      return 0
    fi
  done
  for deb in "$root"/pool/**/*.deb; do
    local extracted="$work/extract-deb"
    rm -rf "$extracted"
    mkdir -p "$extracted"
    if dpkg-deb -x "$deb" "$extracted" && grep -R -q -F "$marker" "$extracted"; then
      return 0
    fi
  done
  return 1
}

start_registry
assert_digest_does_not_follow_tag

if [[ "${#unpinned[@]}" -eq 0 ]]; then
  echo "job container images are digest-pinned; a moved tag is not pulled"
  exit 0
fi

build_rpm libtree-sitter-fedimg FEDORA_IMAGE_PAYLOAD "$work/fedora.rpm"
# The published filename is what fetch-upstream and build-rpm-repos classify.
mv "$work/fedora.rpm" "$work/libtree-sitter-fedimg-1.0-1.fc44.x86_64.rpm"
build_rpm libtree-sitter-suseimg SUSE_IMAGE_PAYLOAD "$work/suse.rpm"
mv "$work/suse.rpm" "$work/libtree-sitter-suseimg-1.0-1.x86_64.rpm"
build_deb "$work/libtree-sitter-evil_9.9.9-1_amd64.deb"

release_db="$work/github-releases"
mkdir -p "$release_db"
host_ws="$work/workspace"
mkdir -p "$host_ws/scripts"
cp "$repo_root/scripts/merge-tree-sitter-manifest.sh" "$host_ws/scripts/"
jq -r '.merge_script' "$work/jobs.json" > "$work/merge.sh"
jq -r '.release_script' "$work/jobs.json" > "$work/release.sh"

changed=false
while IFS= read -r job_name; do
  [[ -n "$job_name" ]] || continue
  job_json="$(jq -c --arg name "$job_name" '.jobs[] | select(.job == $name)' "$work/jobs.json")"
  image="$(jq -r '.image' <<< "$job_json")"
  ref="$(registry_ref_for "$image")"
  case "$job_name" in
    build-rpm) rpm_file="$work/libtree-sitter-fedimg-1.0-1.fc44.x86_64.rpm" ;;
    build-suse-rpm) rpm_file="$work/libtree-sitter-suseimg-1.0-1.x86_64.rpm" ;;
    *) die "unpinned container job $job_name has no payload fixture" ;;
  esac
  build_attacker_image "$ref" "$rpm_file" "$work/libtree-sitter-evil_9.9.9-1_amd64.deb"
  sudo docker push "$ref" >/dev/null
  sudo docker rmi "$ref" >/dev/null 2>&1 || true
  # Same invocation the runner uses: docker pull <image string>.
  sudo docker pull "$ref" >/dev/null
  run_container_job "$job_json" "$ref" "$host_ws" "$release_db"
  if grep -q '^changed=true$' "$host_ws/step-output"; then
    changed=true
  fi
done < <(jq -r '.jobs[] | select(.pinned | not) | .job' "$work/jobs.json")

[[ "$changed" == true ]] || die "container build step did not set the release job output"
[[ -d "$release_db/tree-sitter-$(date -u +%Y-%m-%d)" ]] || die "image shell did not publish a release with the step token"

pages="$work/pages"
publish_trees "$release_db" "$pages"

found=0
if marker_in_tree FEDORA_IMAGE_PAYLOAD "$pages"; then
  echo "FAIL: Fedora job image tag supplied FEDORA_IMAGE_PAYLOAD to the DNF tree"
  found=1
fi
if marker_in_tree SUSE_IMAGE_PAYLOAD "$pages"; then
  echo "FAIL: openSUSE job image tag supplied SUSE_IMAGE_PAYLOAD to the DNF tree"
  found=1
fi
if marker_in_tree DEB_TOKEN_PAYLOAD "$pages"; then
  echo "FAIL: container step token published DEB_TOKEN_PAYLOAD into the APT tree"
  found=1
fi

if [[ "$found" -eq 0 ]]; then
  die "unpinned images did not reach the published trees; reproduction incomplete"
fi
exit 1
