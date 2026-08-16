#!/usr/bin/env bash
set -euo pipefail

pages="${1:?pages directory required}"
out="${pages}/index.html"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${script_dir}/.." && pwd)"
config="${root}/config/repos.json"

if [[ ! -d "$pages" ]]; then
  echo "Pages directory not found: ${pages}" >&2
  exit 1
fi
if [[ ! -f "$config" ]]; then
  echo "Missing ${config}" >&2
  exit 1
fi

sources_tpl="${pages}/sources"
if [[ ! -f "$sources_tpl" ]]; then
  sources_tpl="${root}/docs/sources"
fi
repo_tpl="${pages}/repo"
if [[ ! -f "$repo_tpl" ]]; then
  repo_tpl="${root}/docs/repo"
fi
if [[ ! -f "$sources_tpl" || ! -f "$repo_tpl" ]]; then
  echo "Missing sources or repo template (looked in ${pages} and ${root}/docs)." >&2
  exit 1
fi

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/apt" "${work}/rpm" "${work}/allowlist" "${work}/always"

# APT packages we never ingest because every supported suite already has them.
printf '%s\n' libfaiss-dev > "${work}/always/packages"

mapfile -t apt_suites < <(jq -r '.apt.suites[]' "$config")
if [[ "${#apt_suites[@]}" -eq 0 ]]; then
  echo "No APT suites in ${config}" >&2
  exit 1
fi

allow_i=0
while IFS= read -r suites_json; do
  [[ -n "$suites_json" ]] || continue
  allow_i=$((allow_i + 1))
  jq -r '.[]' <<< "$suites_json" > "${work}/allowlist/${allow_i}"
done < <(jq -c '.projects[] | select((.deb | type) == "object" and (.deb.suites | type) == "array") | .deb.suites' "$config")

record_apt() {
  local pkg="$1" suite="$2" arch="$3" ver="$4"
  [[ -n "$pkg" && -n "$suite" && -n "$arch" && -n "$ver" ]] || return 0
  mkdir -p "${work}/apt/${pkg}/${suite}"
  printf '%s\n' "$ver" > "${work}/apt/${pkg}/${suite}/${arch}"
  printf '%s\n' "$pkg" >> "${work}/pkg-names"
}

record_rpm() {
  local pkg="$1" fc="$2" arch="$3" ver="$4"
  [[ -n "$pkg" && -n "$fc" && -n "$arch" && -n "$ver" ]] || return 0
  mkdir -p "${work}/rpm/${pkg}/${fc}"
  printf '%s\n' "$ver" > "${work}/rpm/${pkg}/${fc}/${arch}"
  printf '%s\n' "$pkg" >> "${work}/pkg-names"
  printf '%s\n' "$fc" >> "${work}/fedora-nums"
}

scan_packages_file() {
  local file="$1" suite="$2" arch="$3"
  local reader=(cat)
  if [[ "$file" == *.gz ]]; then
    reader=(gzip -dc)
  fi
  "${reader[@]}" "$file" | awk -v suite="$suite" -v arch_dir="$arch" '
    $1 == "Package:" { pkg = $2 }
    $1 == "Version:" { ver = $2 }
    $1 == "Architecture:" { arch = $2 }
    /^$/ {
      if (pkg != "" && ver != "") {
        if (arch == "") arch = arch_dir
        print pkg "\t" ver "\t" arch
      }
      pkg = ver = arch = ""
    }
    END {
      if (pkg != "" && ver != "") {
        if (arch == "") arch = arch_dir
        print pkg "\t" ver "\t" arch
      }
    }
  ' | while IFS=$'\t' read -r pkg ver arch; do
    record_apt "$pkg" "$suite" "$arch" "$ver"
  done
}

if [[ -d "${pages}/dists" ]]; then
  while IFS= read -r -d '' file; do
    rel="${file#"${pages}/dists/"}"
    suite="${rel%%/*}"
    rest="${rel#*/}"
    if [[ "$rest" != main/binary-*/* ]]; then
      continue
    fi
    arch_part="${rest#main/binary-}"
    arch="${arch_part%%/*}"
    base="$(basename "$file")"
    if [[ "$base" == Packages.gz && -f "$(dirname "$file")/Packages" ]]; then
      continue
    fi
    scan_packages_file "$file" "$suite" "$arch"
  done < <(find "${pages}/dists" -type f \( -name Packages -o -name Packages.gz \) -print0 | sort -z)
fi

if [[ -d "${pages}/rpm" ]]; then
  shopt -s nullglob
  while IFS= read -r -d '' file; do
    base="$(basename "$file")"
    if [[ "$base" == *debuginfo* || "$base" == *debugsource* ]]; then
      continue
    fi
    rel="${file#"${pages}/rpm/"}"
    if [[ ! "$rel" =~ ^fc([0-9]+)/([^/]+)/([^/]+)$ ]]; then
      continue
    fi
    fc="${BASH_REMATCH[1]}"
    arch="${BASH_REMATCH[2]}"
    if [[ ! "$base" =~ ^(.*)-([^-]+)-([^-]+)\.fc[0-9]+\.[^.]+\.rpm$ ]]; then
      continue
    fi
    pkg="${BASH_REMATCH[1]}"
    ver="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
    record_rpm "$pkg" "$fc" "$arch" "$ver"
  done < <(find "${pages}/rpm" -type f -name '*.rpm' -print0 | sort -z)
  shopt -u nullglob
fi

cat "${work}/always/packages" >> "${work}/pkg-names"
sort -u "${work}/pkg-names" -o "${work}/pkg-names" 2>/dev/null || : > "${work}/pkg-names"

mapfile -t extra_suites < <(
  if [[ -d "${pages}/dists" ]]; then
    find "${pages}/dists" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
  fi
)
declare -A suite_seen=()
apt_columns=()
for suite in "${apt_suites[@]}"; do
  suite_seen["$suite"]=1
  apt_columns+=("$suite")
done
for suite in "${extra_suites[@]}"; do
  [[ -n "$suite" ]] || continue
  [[ -z "${suite_seen[$suite]:-}" ]] || continue
  apt_columns+=("$suite")
done

fedora_columns=()
if [[ -f "${work}/fedora-nums" ]]; then
  mapfile -t fedora_columns < <(sort -n -u "${work}/fedora-nums")
fi

apt_has() {
  local pkg="$1" suite="$2"
  [[ -d "${work}/apt/${pkg}/${suite}" ]]
}

is_always_default() {
  grep -qx "$1" "${work}/always/packages"
}

is_default_source() {
  local pkg="$1" suite="$2"
  if apt_has "$pkg" "$suite"; then
    return 1
  fi
  local allow s
  shopt -s nullglob
  for allow in "${work}/allowlist/"*; do
    if grep -qx "$suite" "$allow"; then
      continue
    fi
    while IFS= read -r s; do
      [[ -n "$s" ]] || continue
      if apt_has "$pkg" "$s"; then
        shopt -u nullglob
        return 0
      fi
    done < "$allow"
  done
  shopt -u nullglob
  is_always_default "$pkg"
}

format_arches() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  local -a arches=() vers=()
  local arch ver first="" same=1
  mapfile -t arches < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
  [[ "${#arches[@]}" -gt 0 ]] || return 1
  for arch in "${arches[@]}"; do
    ver="$(cat "${dir}/${arch}")"
    vers+=("$ver")
    if [[ -z "$first" ]]; then
      first="$ver"
    elif [[ "$ver" != "$first" ]]; then
      same=0
    fi
  done
  if [[ "$same" -eq 1 ]]; then
    if [[ "${#arches[@]}" -eq 1 && "${arches[0]}" != all ]]; then
      printf '%s (%s)\n' "$first" "${arches[0]}"
    else
      printf '%s\n' "$first"
    fi
    return 0
  fi
  local i parts=()
  for i in "${!arches[@]}"; do
    parts+=("${arches[$i]} ${vers[$i]}")
  done
  local IFS='; '
  printf '%s\n' "${parts[*]}"
}

cell_apt() {
  local pkg="$1" suite="$2" text
  if text="$(format_arches "${work}/apt/${pkg}/${suite}")"; then
    printf 'ship\t%s\n' "$text"
    return 0
  fi
  if is_default_source "$pkg" "$suite"; then
    printf 'distro\tdefault sources\n'
    return 0
  fi
  printf 'none\t—\n'
}

cell_rpm() {
  local pkg="$1" fc="$2" text
  if text="$(format_arches "${work}/rpm/${pkg}/${fc}")"; then
    printf 'ship\t%s\n' "$text"
    return 0
  fi
  printf 'none\t—\n'
}

apt_colspan="${#apt_columns[@]}"
fedora_colspan="${#fedora_columns[@]}"

write_html() {
  local suite fc pkg grade text
  cat <<'HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>roojs package repositories</title>
<style>
body { font-family: sans-serif; line-height: 1.4; max-width: 72rem; margin: 1.5rem auto; padding: 0 1rem; }
h1 { margin-bottom: 0.25rem; }
.lead { color: #444; margin-top: 0; }
pre { background: #f4f4f4; padding: 0.75rem 1rem; overflow: auto; }
table { border-collapse: collapse; width: 100%; margin: 1rem 0 2rem; }
th, td { border: 1px solid #888; padding: 0.4rem 0.55rem; vertical-align: top; }
th { background: #eee; }
th.pkg, td.pkg { text-align: left; white-space: nowrap; }
td.ship { font-variant-numeric: tabular-nums; }
td.distro { font-style: italic; color: #333; }
td.none { color: #888; text-align: center; }
.wrap { overflow-x: auto; }
.legend span { display: inline-block; margin-right: 1.25rem; }
@media (prefers-color-scheme: dark) {
  body { background: #111; color: #eee; }
  .lead { color: #bbb; }
  pre { background: #222; }
  th { background: #222; }
  th, td { border-color: #555; }
  td.distro { color: #ccc; }
  td.none { color: #888; }
}
</style>
</head>
<body>
<h1>roojs package repositories</h1>
<p class="lead">Official APT and DNF packages for <a href="https://github.com/roojs">roojs</a> desktop projects. This page is generated from the published repository, not a hand-written list.</p>
HEAD

  printf '<h2>APT (Debian / Ubuntu)</h2>\n'
  printf '<p>Suites:'
  for suite in "${apt_columns[@]}"; do
    printf ' <code>%s</code>' "$(html_escape "$suite")"
  done
  printf '. Architectures: <code>amd64</code>, <code>arm64</code>.</p>\n'

  cat <<'APT'
<p>Add the signing key and the sources file, replacing <code>@suite@</code> with your suite from <code>lsb_release -cs</code>:</p>
<pre>sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://roojs.github.io/repos/key.gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/roojs.gpg

curl -fsSL https://roojs.github.io/repos/sources \
  | sed "s/@suite@/$(lsb_release -cs)/" \
  | sudo tee /etc/apt/sources.list.d/roojs.sources

sudo apt update</pre>
<p>The <code>sources</code> file currently served is:</p>
<pre>
APT
  html_escape "$(cat "$sources_tpl")"
  printf '\n</pre>\n'

  cat <<'DNF'
<h2>DNF (Fedora)</h2>
<p>Repositories are published per Fedora release under <code>rpm/fc&lt;version&gt;/&lt;arch&gt;/</code>. Check your version with <code>rpm -E %fedora</code>.</p>
<pre>sudo curl -fsSL https://roojs.github.io/repos/key.gpg \
  -o /etc/pki/rpm-gpg/RPM-GPG-KEY-roojs
sudo curl -fsSL https://roojs.github.io/repos/repo \
  -o /etc/yum.repos.d/roojs.repo
sudo dnf makecache</pre>
<p>The <code>repo</code> file currently served is:</p>
<pre>
DNF
  html_escape "$(cat "$repo_tpl")"
  printf '\n</pre>\n'

  cat <<'GRID'
<h2>What you can install</h2>
<p class="legend">
<span><strong>version</strong> — we ship it in this repository</span>
<span><em>default sources</em> — already in Debian/Ubuntu; install with <code>apt</code> from the distro</span>
<span><strong>—</strong> — not available from us or from that suite</span>
</p>
<div class="wrap">
<table>
<thead>
GRID

  printf '<tr>\n'
  printf '<th class="pkg" rowspan="2">Package</th>\n'
  printf '<th colspan="%s">APT</th>\n' "$apt_colspan"
  if [[ "$fedora_colspan" -gt 0 ]]; then
    printf '<th colspan="%s">Fedora</th>\n' "$fedora_colspan"
  fi
  printf '</tr>\n<tr>\n'
  for suite in "${apt_columns[@]}"; do
    printf '<th>%s</th>\n' "$(html_escape "$suite")"
  done
  for fc in "${fedora_columns[@]}"; do
    printf '<th>fc%s</th>\n' "$(html_escape "$fc")"
  done
  printf '</tr>\n</thead>\n<tbody>\n'

  if [[ -s "${work}/pkg-names" ]]; then
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      printf '<tr>\n<th class="pkg" scope="row">%s</th>\n' "$(html_escape "$pkg")"
      for suite in "${apt_columns[@]}"; do
        IFS=$'\t' read -r grade text < <(cell_apt "$pkg" "$suite")
        printf '<td class="%s">%s</td>\n' "$grade" "$(html_escape "$text")"
      done
      for fc in "${fedora_columns[@]}"; do
        IFS=$'\t' read -r grade text < <(cell_rpm "$pkg" "$fc")
        printf '<td class="%s">%s</td>\n' "$grade" "$(html_escape "$text")"
      done
      printf '</tr>\n'
    done < "${work}/pkg-names"
  else
    printf '<tr><td colspan="%s">No packages published yet.</td></tr>\n' \
      "$((1 + apt_colspan + fedora_colspan))"
  fi

  cat <<'FOOT'
</tbody>
</table>
</div>
<p>Source: <a href="https://github.com/roojs/repos">github.com/roojs/repos</a></p>
</body>
</html>
FOOT
}

write_html > "${out}.tmp"

mv "${out}.tmp" "$out"
echo "Wrote ${out}"
