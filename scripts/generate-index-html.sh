#!/usr/bin/env bash
set -euo pipefail

pages="${1:?pages directory required}"
out="${pages}/index.html"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${script_dir}/.." && pwd)"
config="${root}/config/repos.json"
tree_sitter_config="${root}/config/tree-sitter.json"
# shellcheck source=lib/repos-config.sh
source "${script_dir}/lib/repos-config.sh"

owner="$(jq -r '.owner' "$config")"
github_base="https://github.com/${owner}"

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
mkdir -p "${work}/apt" "${work}/rpm" "${work}/opensuse" "${work}/allowlist" "${work}/always" "${work}/desc" "${work}/group" "${work}/url"

load_pkg_source_urls() {
  local repo url
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    url="${github_base}/${repo}"
    case "$repo" in
      OLLMchat) printf '%s\n' "$url" > "${work}/url/ollmchat" ;;
      app.RooTerm) printf '%s\n' "$url" > "${work}/url/rooterm" ;;
      roobuilder)
        printf '%s\n' "$url" > "${work}/url/roobuilder"
        printf '%s\n' "$url" > "${work}/url/roojspacker"
        ;;
      ibus-sherpa-onnx) printf '%s\n' "$url" > "${work}/url/ibus-sherpa-onnx" ;;
      sherpa-onnx) printf '%s\n' "$url" > "${work}/url/sherpa-onnx" ;;
      webkitgtk-automation)
        printf '%s\n' "$url" > "${work}/url/webkitgtk-automation"
        ;;
      repos) printf '%s\n' "$url" > "${work}/url/repos" ;;
    esac
  done < <(jq -r '.projects[].repo' "$config")

  if [[ -f "$tree_sitter_config" ]]; then
    while IFS=$'\t' read -r id url; do
      [[ -n "$id" && -n "$url" ]] || continue
      printf '%s\n' "$url" > "${work}/url/libtree-sitter-${id}"
    done < <(jq -r '.parsers[] | "\(.id)\t\(.repo)"' "$tree_sitter_config")
    printf '%s\n' "https://github.com/tree-sitter/tree-sitter" > "${work}/url/libtree-sitter-dev"
  fi
}
load_pkg_source_urls

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

record_desc() {
  local pkg="$1" desc="$2"
  [[ -n "$pkg" && -n "$desc" ]] || return 0
  if [[ ! -f "${work}/desc/${pkg}" ]]; then
    printf '%s\n' "$desc" > "${work}/desc/${pkg}"
  fi
}

record_apt() {
  local pkg="$1" suite="$2" arch="$3" ver="$4" desc="${5:-}"
  [[ -n "$pkg" && -n "$suite" && -n "$arch" && -n "$ver" ]] || return 0
  mkdir -p "${work}/apt/${pkg}/${suite}"
  printf '%s\n' "$ver" > "${work}/apt/${pkg}/${suite}/${arch}"
  printf '%s\n' "$pkg" >> "${work}/pkg-names"
  record_desc "$pkg" "$desc"
}

record_rpm() {
  local pkg="$1" fc="$2" arch="$3" ver="$4"
  [[ -n "$pkg" && -n "$fc" && -n "$arch" && -n "$ver" ]] || return 0
  mkdir -p "${work}/rpm/${pkg}/${fc}"
  printf '%s\n' "$ver" > "${work}/rpm/${pkg}/${fc}/${arch}"
  printf '%s\n' "$pkg" >> "${work}/pkg-names"
  printf '%s\n' "$fc" >> "${work}/fedora-nums"
}

record_opensuse() {
  local pkg="$1" release="$2" arch="$3" ver="$4"
  [[ -n "$pkg" && -n "$release" && -n "$arch" && -n "$ver" ]] || return 0
  mkdir -p "${work}/opensuse/${pkg}/${release}"
  printf '%s\n' "$ver" > "${work}/opensuse/${pkg}/${release}/${arch}"
  printf '%s\n' "$pkg" >> "${work}/pkg-names"
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
    $1 == "Description:" {
      desc = $0
      sub(/^Description:[ \t]*/, "", desc)
      gsub(/\t/, " ", desc)
    }
    /^$/ {
      if (pkg != "" && ver != "") {
        if (arch == "") arch = arch_dir
        print pkg "\t" ver "\t" arch "\t" desc
      }
      pkg = ver = arch = desc = ""
    }
    END {
      if (pkg != "" && ver != "") {
        if (arch == "") arch = arch_dir
        print pkg "\t" ver "\t" arch "\t" desc
      }
    }
  ' | while IFS=$'\t' read -r pkg ver arch desc; do
    record_apt "$pkg" "$suite" "$arch" "$ver" "$desc"
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
    if [[ "$rel" =~ ^fc([0-9]+)/([^/]+)/([^/]+)$ ]]; then
      fc="${BASH_REMATCH[1]}"
      arch="${BASH_REMATCH[2]}"
      if [[ "$base" =~ ^(.+)-([^-]+)-([^-]+)\.fc[0-9]+\.[^.]+\.rpm$ ]]; then
        pkg="${BASH_REMATCH[1]}"
        ver="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
      elif [[ "$base" =~ ^(.+)-([^-]+)-([^-]+)\.([^.]+)\.rpm$ ]]; then
        pkg="${BASH_REMATCH[1]}"
        ver="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
      else
        continue
      fi
      record_rpm "$pkg" "$fc" "$arch" "$ver"
    elif [[ "$rel" =~ ^tumbleweed/([^/]+)/([^/]+)$ ]]; then
      release="tumbleweed"
      arch="${BASH_REMATCH[1]}"
      if [[ "$base" =~ ^(.+)-([^-]+)-([^-]+)\.([^.]+)\.rpm$ ]] && [[ "$base" != *\.fc* ]]; then
        pkg="${BASH_REMATCH[1]}"
        ver="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
        record_opensuse "$pkg" "$release" "$arch" "$ver"
      fi
    fi
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

mapfile -t opensuse_columns < <(repos_config_opensuse_releases "$config")

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

debian_columns=()
ubuntu_columns=()
for suite in "${apt_columns[@]}"; do
  case "$suite" in
    bookworm|trixie|forky|sid)
      debian_columns+=("$suite")
      ;;
    *)
      ubuntu_columns+=("$suite")
      ;;
  esac
done

package_group() {
  case "$1" in
    libtree-sitter-*)
      printf '%s\n' treesitter
      ;;
    ollmchat*|liboc*|libollm*|libollamaweb*|libllama*|llama-*|libggml*|ggml-*|libfaiss*|faiss*|python3-faiss)
      printf '%s\n' ollmchat
      ;;
    *webkit*|*javascriptcore*)
      printf '%s\n' webkit
      ;;
    *sherpa*)
      printf '%s\n' speech
      ;;
    rooterm)
      printf '%s\n' rooterm
      ;;
    roobuilder|roojspacker)
      printf '%s\n' roobuilder
      ;;
    *)
      printf '%s\n' other
      ;;
  esac
}

package_group_title() {
  case "$1" in
    treesitter) printf '%s\n' "Tree-sitter" ;;
    ollmchat) printf '%s\n' OLLMchat ;;
    webkit) printf '%s\n' WebKit ;;
    speech) printf '%s\n' "Speech (STT / TTS)" ;;
    rooterm) printf '%s\n' RooTerm ;;
    roobuilder) printf '%s\n' RooBuilder ;;
    *) printf '%s\n' Other ;;
  esac
}

package_group_blurb() {
  case "$1" in
    treesitter)
      printf '%s\n' "Grammar parsers used by <a href=\"https://github.com/roojs/OLLMchat\">OLLMchat</a> to split documents for semantic search. Each row links to the upstream grammar repository."
      ;;
    ollmchat)
      printf '%s\n' "<a href=\"https://github.com/roojs/OLLMchat\">OLLMchat</a> and the <a href=\"https://github.com/ggml-org/llama.cpp\">llama.cpp</a> / <a href=\"https://github.com/facebookresearch/faiss\">FAISS</a> libraries it uses. llama.cpp and FAISS packages are repackaged from Debian."
      ;;
    webkit)
      printf '%s\n' "WebKitGTK builds with <strong>WebDriver</strong> automation. Install the runtime with <code>libwebkitgtk-6.0-webdriver4</code> and headers with <code>libwebkitgtk-6.0-webdriver-dev</code>."
      ;;
    speech)
      printf '%s\n' "<a href=\"https://github.com/roojs/sherpa-onnx\">Sherpa-ONNX</a> libraries and the <a href=\"https://github.com/roojs/ibus-sherpa-onnx\">IBus engine</a>."
      ;;
    rooterm)
      printf '%s\n' "<a href=\"https://github.com/roojs/app.RooTerm\">Terminal emulator</a>."
      ;;
    roobuilder)
      printf '%s\n' "<a href=\"https://github.com/roojs/roobuilder\">Vala UI builder</a> and JavaScript packer."
      ;;
    *) printf '%s\n' "" ;;
  esac
}

pkg_source_url() {
  local pkg="$1" id url
  if [[ -f "${work}/url/${pkg}" ]]; then
    cat "${work}/url/${pkg}"
    return 0
  fi
  case "$pkg" in
    libllama*|llama-*|libggml*|ggml-*)
      printf '%s\n' "https://github.com/ggml-org/llama.cpp"
      return 0
      ;;
    libfaiss*|faiss*|python3-faiss)
      printf '%s\n' "https://github.com/facebookresearch/faiss"
      return 0
      ;;
    *webkit*|*javascriptcore*)
      printf '%s\n' "${github_base}/webkitgtk-automation"
      return 0
      ;;
    ibus-sherpa-onnx)
      printf '%s\n' "${github_base}/ibus-sherpa-onnx"
      return 0
      ;;
    *sherpa*)
      printf '%s\n' "${github_base}/sherpa-onnx"
      return 0
      ;;
    libtree-sitter-*)
      id="${pkg#libtree-sitter-}"
      id="${id%-dev}"
      if [[ -f "${work}/url/libtree-sitter-${id}" ]]; then
        cat "${work}/url/libtree-sitter-${id}"
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

pkg_repackaged_note() {
  case "$1" in
    libllama*|llama-*|libggml*|ggml-*)
      printf '%s\n' "Repackaged from Debian."
      ;;
    libfaiss*|faiss*|python3-faiss|faiss-devel)
      printf '%s\n' "Repackaged from Debian."
      ;;
    *)
      return 1
      ;;
  esac
}

pkg_desc() {
  local pkg="$1" desc note
  case "$pkg" in
    libwebkitgtk-6.0-webdriver4) desc="WebKitGTK WebDriver runtime library" ;;
    libwebkitgtk-6.0-webdriver-dev) desc="WebKitGTK WebDriver development files" ;;
    *)
      if [[ -f "${work}/desc/${pkg}" ]]; then
        desc="$(cat "${work}/desc/${pkg}")"
      else
        case "$pkg" in
          libfaiss-dev) desc="FAISS vector search library" ;;
          libfaiss) desc="FAISS vector search library" ;;
          faiss-devel) desc="FAISS development headers" ;;
          ollmchat) desc="Local LLM chat" ;;
          rooterm) desc="Terminal emulator" ;;
          ibus-sherpa-onnx) desc="IBus on-device speech recognition" ;;
          roobuilder) desc="Vala UI builder" ;;
          roojspacker) desc="JavaScript packer" ;;
          libllama0|libllama-dev) desc="llama.cpp inference library" ;;
          *) desc="" ;;
        esac
      fi
      ;;
  esac
  note="$(pkg_repackaged_note "$pkg" || true)"
  if [[ -n "$note" ]]; then
    if [[ -n "$desc" ]]; then
      printf '%s %s\n' "$desc" "$note"
    else
      printf '%s\n' "$note"
    fi
    return 0
  fi
  if [[ -n "$desc" ]]; then
    printf '%s\n' "$desc"
  fi
  return 0
}

if [[ -s "${work}/pkg-names" ]]; then
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    printf '%s\n' "$pkg" >> "${work}/group/$(package_group "$pkg")"
  done < "${work}/pkg-names"
  for group_file in "${work}/group/"*; do
    [[ -f "$group_file" ]] || continue
    sort -u "$group_file" -o "$group_file"
  done
fi

headline_version() {
  local ver="$1"
  ver="${ver#*:}"
  if [[ "$ver" == *+* ]]; then
    local upstream="${ver%%-*}"
    local suffix="${ver#*+}"
    printf '%s+%s\n' "$upstream" "$suffix"
    return 0
  fi
  if [[ "$ver" == *-* ]]; then
    ver="${ver%-*}"
  fi
  if [[ "$ver" == *~* ]]; then
    ver="${ver%%~*}"
  fi
  printf '%s\n' "$ver"
}

format_ship_html() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  local -a arches=() vers=() show=()
  local arch ver first="" same=1
  mapfile -t arches < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
  [[ "${#arches[@]}" -gt 0 ]] || return 1
  for arch in "${arches[@]}"; do
    ver="$(headline_version "$(cat "${dir}/${arch}")")"
    vers+=("$ver")
    if [[ "$arch" != all ]]; then
      show+=("$arch")
    fi
    if [[ -z "$first" ]]; then
      first="$ver"
    elif [[ "$ver" != "$first" ]]; then
      same=0
    fi
  done
  local i
  if [[ "$same" -eq 1 ]]; then
    printf '<span class="ver">%s</span>' "$(html_escape "$first")"
    if [[ "${#show[@]}" -gt 0 ]]; then
      local joined
      printf -v joined '%s, ' "${show[@]}"
      printf '<span class="arch">%s</span>' "$(html_escape "${joined%, }")"
    fi
    return 0
  fi
  for i in "${!arches[@]}"; do
    printf '<span class="ver">%s</span>' "$(html_escape "${vers[$i]}")"
    if [[ "${arches[$i]}" != all ]]; then
      printf '<span class="arch">%s</span>' "$(html_escape "${arches[$i]}")"
    fi
  done
}

already_in_html() {
  printf '<span class="ver">already in</span><span class="arch">%s</span>' "$(html_escape "$1")"
}

apt_suite_distro() {
  local suite="$1" s
  for s in "${debian_columns[@]}"; do
    if [[ "$s" == "$suite" ]]; then
      printf '%s\n' Debian
      return 0
    fi
  done
  printf '%s\n' Ubuntu
}

apt_suite_release() {
  case "$1" in
    bookworm) printf '%s\n' "12" ;;
    trixie) printf '%s\n' "13" ;;
    forky) printf '%s\n' "14" ;;
    sid) printf '%s\n' "unstable" ;;
    plucky) printf '%s\n' "25.04" ;;
    questing) printf '%s\n' "25.10" ;;
    resolute) printf '%s\n' "26.04" ;;
    noble) printf '%s\n' "24.04" ;;
    jammy) printf '%s\n' "22.04" ;;
    *) return 1 ;;
  esac
}

is_debian_suite() {
  local suite="$1" s
  for s in "${debian_columns[@]}"; do
    [[ "$s" == "$suite" ]] && return 0
  done
  return 1
}

write_apt_suite_intro() {
  local suite="$1" release codename distro parts=()
  for suite in "$@"; do
    release="$(apt_suite_release "$suite" || true)"
    codename="$(html_escape "$suite")"
    if [[ -n "$release" ]]; then
      if is_debian_suite "$suite"; then
        distro="Debian"
      else
        distro="Ubuntu"
      fi
      parts+=("$(html_escape "$distro") $(html_escape "$release") (<code>${codename}</code>)")
    else
      parts+=("<code>${codename}</code>")
    fi
  done
  local joined
  printf -v joined '%s, ' "${parts[@]}"
  printf '%s' "${joined%, }"
}

write_apt_suite_th() {
  local suite="$1" release codename distro
  release="$(apt_suite_release "$suite" || true)"
  codename="$(html_escape "$suite")"
  if [[ -n "$release" ]]; then
    if is_debian_suite "$suite"; then
      distro="Debian"
    else
      distro="Ubuntu"
    fi
    printf '<th class="suite"><span class="suite-release">%s %s</span><span class="suite-codename">%s</span></th>\n' \
      "$(html_escape "$distro")" "$(html_escape "$release")" "$codename"
  else
    printf '<th class="suite">%s</th>\n' "$codename"
  fi
}

write_fedora_th() {
  local fc="$1"
  printf '<th class="suite"><span class="suite-release">Fedora %s</span><span class="suite-codename">fc%s</span></th>\n' \
    "$(html_escape "$fc")" "$(html_escape "$fc")"
}

write_opensuse_th() {
  local release="$1"
  case "$release" in
    tumbleweed)
      printf '<th class="suite"><span class="suite-release">openSUSE Tumbleweed</span><span class="suite-codename">rolling</span></th>\n'
      ;;
    *)
      printf '<th class="suite"><span class="suite-release">openSUSE %s</span><span class="suite-codename">%s</span></th>\n' \
        "$(html_escape "$release")" "$(html_escape "$release")"
      ;;
  esac
}

is_fedora_upstream() {
  case "$1" in
    *webdriver*)
      return 1
      ;;
    libllama*|llama-*|libggml*|ggml-*|*webkit*|*javascriptcore*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_opensuse_upstream() {
  case "$1" in
    *webdriver*)
      return 1
      ;;
    libllama*|llama-*|libggml*|ggml-*|libfaiss*|faiss*|python3-faiss|*webkit*|*javascriptcore*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

rpm_pkg_name() {
  case "$1" in
    libfaiss-dev) printf '%s\n' libfaiss ;;
    *) printf '%s\n' "$1" ;;
  esac
}

cell_apt() {
  local pkg="$1" suite="$2" html
  if html="$(format_ship_html "${work}/apt/${pkg}/${suite}")"; then
    printf 'ship\t%s\n' "$html"
    return 0
  fi
  if is_default_source "$pkg" "$suite"; then
    printf 'distro\t%s\n' "$(already_in_html "$(apt_suite_distro "$suite")")"
    return 0
  fi
  printf 'none\t—\n'
}

cell_rpm() {
  local pkg="$1" fc="$2" html rpm_pkg
  rpm_pkg="$(rpm_pkg_name "$pkg")"
  if html="$(format_ship_html "${work}/rpm/${rpm_pkg}/${fc}")"; then
    printf 'ship\t%s\n' "$html"
    return 0
  fi
  if is_fedora_upstream "$pkg"; then
    printf 'distro\t%s\n' "$(already_in_html Fedora)"
    return 0
  fi
  printf 'none\t—\n'
}

cell_opensuse() {
  local pkg="$1" release="$2" html rpm_pkg
  rpm_pkg="$(rpm_pkg_name "$pkg")"
  if html="$(format_ship_html "${work}/opensuse/${rpm_pkg}/${release}")"; then
    printf 'ship\t%s\n' "$html"
    return 0
  fi
  if is_opensuse_upstream "$pkg"; then
    printf 'distro\t%s\n' "$(already_in_html openSUSE)"
    return 0
  fi
  printf 'none\t—\n'
}

write_pkg_th() {
  local pkg="$1" desc url
  printf '<th class="pkg" scope="row"><span class="pkg-name">'
  url="$(pkg_source_url "$pkg" || true)"
  if [[ -n "$url" ]]; then
    printf '<a href="%s" class="pkg-link">%s</a>' "$(html_escape "$url")" "$(html_escape "$pkg")"
  else
    printf '%s' "$(html_escape "$pkg")"
  fi
  printf '</span>'
  desc="$(pkg_desc "$pkg")"
  if [[ -n "$desc" ]]; then
    printf '<span class="pkg-desc">%s</span>' "$(html_escape "$desc")"
  fi
  printf '</th>\n'
}

write_apt_td() {
  local pkg="$1" suite="$2" grade html
  IFS=$'\t' read -r grade html < <(cell_apt "$pkg" "$suite")
  printf '<td class="%s">%s</td>\n' "$grade" "$html"
}

write_rpm_td() {
  local pkg="$1" fc="$2" grade html
  IFS=$'\t' read -r grade html < <(cell_rpm "$pkg" "$fc")
  printf '<td class="%s">%s</td>\n' "$grade" "$html"
}

write_opensuse_td() {
  local pkg="$1" release="$2" grade html
  IFS=$'\t' read -r grade html < <(cell_opensuse "$pkg" "$release")
  printf '<td class="%s">%s</td>\n' "$grade" "$html"
}

write_group_table() {
  local pkgfile="$1" pkg suite fc release
  local debian_span="${#debian_columns[@]}"
  local ubuntu_span="${#ubuntu_columns[@]}"
  local fedora_span="${#fedora_columns[@]}"
  local opensuse_span="${#opensuse_columns[@]}"
  printf '<div class="wrap"><table>\n<thead>\n<tr>\n'
  printf '<th class="pkg" rowspan="2">Package</th>\n'
  if [[ "$debian_span" -gt 0 ]]; then
    printf '<th colspan="%s">Debian</th>\n' "$debian_span"
  fi
  if [[ "$ubuntu_span" -gt 0 ]]; then
    printf '<th colspan="%s">Ubuntu</th>\n' "$ubuntu_span"
  fi
  if [[ "$fedora_span" -gt 0 ]]; then
    printf '<th colspan="%s">Fedora</th>\n' "$fedora_span"
  fi
  if [[ "$opensuse_span" -gt 0 ]]; then
    printf '<th colspan="%s">openSUSE</th>\n' "$opensuse_span"
  fi
  printf '</tr>\n<tr>\n'
  for suite in "${debian_columns[@]}"; do
    write_apt_suite_th "$suite"
  done
  for suite in "${ubuntu_columns[@]}"; do
    write_apt_suite_th "$suite"
  done
  for fc in "${fedora_columns[@]}"; do
    write_fedora_th "$fc"
  done
  for release in "${opensuse_columns[@]}"; do
    write_opensuse_th "$release"
  done
  printf '</tr>\n</thead>\n<tbody>\n'
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    printf '<tr>\n'
    write_pkg_th "$pkg"
    for suite in "${debian_columns[@]}"; do
      write_apt_td "$pkg" "$suite"
    done
    for suite in "${ubuntu_columns[@]}"; do
      write_apt_td "$pkg" "$suite"
    done
    for fc in "${fedora_columns[@]}"; do
      write_rpm_td "$pkg" "$fc"
    done
    for release in "${opensuse_columns[@]}"; do
      write_opensuse_td "$pkg" "$release"
    done
    printf '</tr>\n'
  done < "$pkgfile"
  printf '</tbody>\n</table>\n</div>\n'
}

write_html() {
  local suite gid title blurb
  cat <<'HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>roojs package repositories</title>
<style>
body { font-family: sans-serif; line-height: 1.4; max-width: 60rem; margin: 1.5rem auto; padding: 0 1rem; }
h1 { margin-bottom: 0.25rem; }
h3 { margin: 1.75rem 0 0.2rem; }
.lead, .group-lead { color: #444; margin-top: 0; }
pre { background: #f4f4f4; padding: 0.75rem 1rem; overflow: auto; }
table { border-collapse: collapse; width: auto; margin: 0 0 0.5rem; }
th, td { border: 1px solid #888; padding: 0.35rem 0.45rem; vertical-align: top; }
th { background: #eee; }
th.pkg { text-align: left; min-width: 9rem; max-width: 16rem; }
.pkg-name { display: block; }
.pkg-link { color: inherit; text-decoration: none; }
.pkg-link:hover { text-decoration: underline; }
.pkg-desc { display: block; font-weight: 400; font-size: 0.8em; color: #555; }
th.suite .suite-release { display: block; font-variant-numeric: tabular-nums; }
th.suite .suite-codename { display: block; font-weight: 400; font-size: 0.75em; color: #555; }
td { text-align: center; max-width: 6.5rem; }
td.ship .ver, td.distro .ver { display: block; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
td.ship .arch, td.distro .arch { display: block; font-size: 0.75em; color: #666; }
td.distro { font-style: italic; }
td.none { color: #888; }
.wrap { overflow-x: auto; }
.legend span { display: inline-block; margin-right: 1.25rem; }
@media (prefers-color-scheme: dark) {
  body { background: #111; color: #eee; }
  .lead, .group-lead { color: #bbb; }
  pre { background: #222; }
  th { background: #222; }
  th, td { border-color: #555; }
  .pkg-desc, td.ship .arch, td.distro .arch, th.suite .suite-codename { color: #aaa; }
  td.none { color: #888; }
}
</style>
</head>
<body>
<h1>roojs package repositories</h1>
<p class="lead">Official APT and DNF packages for <a href="https://github.com/roojs">roojs</a> desktop projects. This page is generated from the published repository, not a hand-written list.</p>
HEAD

  printf '<h2>APT</h2>\n<p>'
  if [[ "${#debian_columns[@]}" -gt 0 ]]; then
    printf 'Debian: '
    write_apt_suite_intro "${debian_columns[@]}"
    printf '.'
  fi
  if [[ "${#ubuntu_columns[@]}" -gt 0 ]]; then
    printf ' Ubuntu: '
    write_apt_suite_intro "${ubuntu_columns[@]}"
    printf '.'
  fi
  printf ' Architectures: <code>amd64</code>.</p>\n'

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
<span><em>already in Debian / Ubuntu / Fedora / openSUSE</em> — not required; use the distro package</span>
<span><strong>—</strong> — not available from us or from that distro</span>
</p>
GRID

  if [[ -s "${work}/pkg-names" ]]; then
    for gid in ollmchat treesitter webkit speech rooterm roobuilder other; do
      [[ -s "${work}/group/${gid}" ]] || continue
      title="$(package_group_title "$gid")"
      blurb="$(package_group_blurb "$gid")"
      printf '<h3>%s</h3>\n' "$(html_escape "$title")"
      if [[ -n "$blurb" ]]; then
        printf '<p class="group-lead">%s</p>\n' "$blurb"
      fi
      write_group_table "${work}/group/${gid}"
    done
  else
    printf '<p>No packages published yet.</p>\n'
  fi

  cat <<'FOOT'
<p>Source: <a href="https://github.com/roojs/repos">github.com/roojs/repos</a></p>
</body>
</html>
FOOT
}

write_html > "${out}.tmp"

mv "${out}.tmp" "$out"
echo "Wrote ${out}"
