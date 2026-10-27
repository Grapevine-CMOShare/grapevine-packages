# Shared helpers for company-arch-packages. Source from other scripts.
# COMPANY_ROOT overrides the repo root (tests).
# shellcheck shell=bash

_PKG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${COMPANY_ROOT:-${ROOT:-$(cd "$_PKG_LIB_DIR/.." && pwd)}}"
ALLOW="${ALLOW:-$ROOT/allowlist.txt}"
PACKAGES="${PACKAGES:-$ROOT/packages}"

company_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

company_valid_pkgname() {
  [[ "$1" =~ ^[a-z0-9][+a-z0-9._-]*$ ]]
}

company_valid_host() {
  local h=$1
  [[ "$h" == *.* ]] || return 1
  [[ "$h" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]
}

# actual hostname is expected or a subdomain of expected.
company_host_ok() {
  local actual=$1 expected=$2
  [[ -n "$actual" && -n "$expected" ]] || return 1
  [[ "$actual" == "$expected" || "$actual" == *."$expected" ]]
}

company_trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# OWNER/REPO from git origin at $1 (default ROOT). Empty + nonzero if missing/unparseable.
company_github_nwo() {
  local root=${1:-$ROOT} url slug
  url=$(git -C "$root" remote get-url origin 2>/dev/null || true)
  [[ -n "$url" ]] || return 1
  url="${url%.git}"
  url="${url%/}"
  case "$url" in
    git@github.com:*) slug="${url#git@github.com:}" ;;
    ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
    https://github.com/*) slug="${url#https://github.com/}" ;;
    http://github.com/*) slug="${url#http://github.com/}" ;;
    *) return 1 ;;
  esac
  slug="${slug#/}"
  [[ "$slug" == */* && "$slug" != */*/* ]] || return 1
  printf '%s\n' "$slug"
}

# Pacman Server= URL. COMPANY_REPO_SERVER, then git origin, then $root/repo-server.
company_repo_server() {
  local root=${1:-$ROOT} line slug
  if [[ -n "${COMPANY_REPO_SERVER:-}" ]]; then
    printf '%s\n' "$COMPANY_REPO_SERVER"
    return 0
  fi
  if slug=$(company_github_nwo "$root"); then
    printf 'https://github.com/%s/releases/latest/download\n' "$slug"
    return 0
  fi
  if [[ -f "$root/repo-server" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
      line=$(company_trim "$line")
      [[ -n "$line" ]] || continue
      printf '%s\n' "$line"
      return 0
    done <"$root/repo-server"
  fi
  return 1
}

company_allowlist() {
  [[ -f "$ALLOW" ]] || company_fail "missing allowlist.txt"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    line=$(company_trim "$line")
    [[ -n "$line" ]] || continue
    printf '%s\n' "$line"
  done <"$ALLOW"
}

company_package_dirs() {
  [[ -d "$PACKAGES" ]] || return 0
  (
    shopt -s nullglob
    for d in "$PACKAGES"/*/; do
      basename "${d%/}"
    done
  )
}

company_upstream_file() { printf '%s\n' "$PACKAGES/$1/upstream"; }
company_pkgbuild_file() { printf '%s\n' "$PACKAGES/$1/PKGBUILD"; }

# key=value file (upstream). First match. Values may contain '='.
company_kv_get() {
  local file=$1 key=$2
  [[ -f "$file" ]] || return 1
  awk -v k="$key" '
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*(#|$)/) next
      if (index(line, k "=") == 1) {
        print substr(line, length(k) + 2)
        exit
      }
    }
  ' "$file"
}

# First assignment of KEY= in a PKGBUILD; strips quotes, parens, whitespace.
company_pkgbuild_get() {
  local file=$1 key=$2
  awk -v k="$key" '
    $0 ~ "^" k "=" {
      sub(/^[^=]+=/, "")
      gsub(/["'\''()[:space:]]/, "")
      print
      exit
    }
  ' "$file"
}

# https:// URLs inside the source=(...) assignment (single- or multi-line).
company_source_urls() {
  local file=$1
  awk '
    BEGIN { in_src = 0 }
    /^source=/ { in_src = 1 }
    in_src {
      s = $0
      while (match(s, /https:\/\/[^"'\'' )]+/)) {
        print substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
      }
      if ($0 ~ /\)/) exit
    }
  ' "$file"
}

company_url_host() {
  local url=$1
  case "$url" in
    https://*) url="${url#https://}" ;;
    http://*) url="${url#http://}" ;;
    file://*) printf '\n'; return 0 ;;
    *) printf '\n'; return 1 ;;
  esac
  url="${url%%/*}"
  url="${url%%:*}"
  printf '%s\n' "$url"
}

company_url_scheme_ok() {
  local url=$1
  case "$url" in
    https://*) return 0 ;;
    file://*)
      [[ "${COMPANY_ALLOW_FILE_SUMS:-}" == 1 ]] || return 1
      return 0
      ;;
    *) return 1 ;;
  esac
}

company_expand_glob() {
  local glob=$1 ver=$2
  printf '%s\n' "${glob//\{pkgver\}/$ver}"
}

# sums_format= in upstream. Default sha256sum (Keeper). debian-packages for apt
# Packages. sha256-of-url for vendors that publish the artifact but no checksums file
# (hash the fetched sums_url body; basename is the optional 3rd arg).
# json-name-targz: sums_url is a JSON object with "name" and "url_targz"
# (GitKraken RELEASES). Verify/propose hash the tarball; this helper does not.
# studio-download-html: sums_url is the Android Studio download page. One linux
# ide-zips tarball URL, and the sha256 printed next to that basename.
company_sums_format() {
  local up=$1 f
  f=$(company_kv_get "$up" sums_format) || true
  f=$(company_trim "$f")
  [[ -n "$f" ]] || f=sha256sum
  printf '%s\n' "$f"
}

# Debian Packages stanzas -> sha256sum lines (HASH  basename).
company_debian_packages_to_sha256sum() {
  awk '
    function trim(s) {
      sub(/\r$/, "", s)
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function emit() {
      if (sha ~ /^[0-9a-fA-F]{64}$/ && fn != "") {
        n = fn
        sub(/^.*\//, "", n)
        print tolower(sha) "  " n
      }
      sha = ""
      fn = ""
    }
    /^Filename:/ {
      line = $0
      sub(/^Filename:/, "", line)
      fn = trim(line)
      next
    }
    /^SHA256:/ {
      line = $0
      sub(/^SHA256:/, "", line)
      sha = trim(line)
      next
    }
    /^[[:space:]]*$/ { emit(); next }
    END { emit() }
  ' "$1"
}

# Print vendor checksums as sha256sum lines.
# format: sha256sum | debian-packages | sha256-of-url
# For sha256-of-url, $3 is the basename written on the line (required).
company_sums_as_sha256sum() {
  local src=$1 format=$2 base=${3:-}
  case "$format" in
    sha256sum)
      cat "$src"
      ;;
    debian-packages)
      company_debian_packages_to_sha256sum "$src"
      ;;
    sha256-of-url)
      [[ -n "$base" ]] || return 1
      printf '%s  %s\n' "$(sha256sum "$src" | awk '{print $1}')" "$base"
      ;;
    *)
      return 1
      ;;
  esac
}

# First "key":"value" string in a flat JSON object. Literal match, not regex.
company_json_string_field() {
  local file=$1 key=$2
  tr -d '\n' <"$file" | awk -v k="$key" '
    BEGIN { found = 0 }
    {
      pat = "\"" k "\":\""
      i = index($0, pat)
      if (i == 0) next
      rest = substr($0, i + length(pat))
      q = index(rest, "\"")
      if (q == 0) next
      print substr(rest, 1, q - 1)
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  '
}

# Version from a json-name-targz document (the "name" field).
company_json_name_targz_version() {
  local name
  name=$(company_json_string_field "$1" name) || {
    echo 'RELEASES JSON missing name' >&2
    return 1
  }
  [[ "$name" =~ ^[0-9.]+$ ]] || {
    echo "release name is not a numeric version: $name" >&2
    return 1
  }
  printf '%s\n' "$name"
}

# Artifact URL from a json-name-targz document.
# $2 is the version to hash. Empty means the published url_targz (latest).
# A different version replaces the /<published>/ path segment.
company_json_name_targz_url() {
  local json=$1 want=$2
  local name url name_re replaced
  name=$(company_json_name_targz_version "$json") || return 1
  url=$(company_json_string_field "$json" url_targz) || {
    echo 'RELEASES JSON missing url_targz' >&2
    return 1
  }
  if [[ -n "$want" && "$want" != "$name" ]]; then
    [[ "$want" =~ ^[0-9.]+$ ]] || {
      echo "pkgver is not a numeric version: $want" >&2
      return 1
    }
    name_re=${name//./\\.}
    replaced=$(printf '%s\n' "$url" | sed "s|/${name_re}/|/${want}/|") || return 1
    if [[ "$replaced" == "$url" ]]; then
      echo "version $want not found in artifact URL" >&2
      return 1
    fi
    url=$replaced
  fi
  printf '%s\n' "$url"
}

# Substitute ${pkgver} and ${_archive} in one PKGBUILD source URL.
company_expand_pkg_url() {
  local pkg=$1 url=$2 pkgver archive
  pkgver=$(company_pkgbuild_get "$pkg" pkgver)
  archive=$(company_kv_line "$pkg" _archive)
  url=${url//\$\{pkgver\}/$pkgver}
  url=${url//\$pkgver/$pkgver}
  if [[ "$url" == *'${_archive}'* || "$url" == *'$_archive'* ]]; then
    [[ -n "$archive" ]] || {
      echo 'PKGBUILD source uses _archive but _archive= is empty' >&2
      return 1
    }
    url=${url//\$\{_archive\}/$archive}
    url=${url//\$_archive/$archive}
  fi
  if [[ "$url" == *'$'* ]]; then
    echo "PKGBUILD source URL still has an unexpanded variable: $url" >&2
    return 1
  fi
  printf '%s\n' "$url"
}

# First KEY= value, or empty. PKGBUILD and upstream files both use this shape.
company_kv_line() {
  local file=$1 key=$2
  company_pkgbuild_get "$file" "$key" || true
}

# True when basename matches sums_glob (bash pattern, {pkgver} already expanded).
company_basename_matches_glob() {
  local base=$1 glob=$2
  # Right-hand side is a pattern, not a pathname.
  # shellcheck disable=SC2254
  [[ "$base" == $glob ]]
}

# studio-download-html. stdout is four lines: version, url, sha256, basename.
company_studio_download_linux() {
  local file=$1
  local urls url ver base sha n
  mapfile -t urls < <(grep -oE 'https://[^"'\''[:space:]<>]+/android/studio/ide-zips/[0-9.]+/android-studio-[A-Za-z0-9._-]+-linux\.tar\.gz' "$file" | sort -u || true)
  n=${#urls[@]}
  if [[ "$n" -ne 1 ]]; then
    echo "expected one linux ide-zips URL, found $n" >&2
    return 1
  fi
  url=${urls[0]}
  ver=$(printf '%s\n' "$url" | sed -n 's|.*/ide-zips/\([0-9.][0-9.]*\)/android-studio-.*|\1|p')
  [[ "$ver" =~ ^[0-9.]+$ ]] || {
    echo "linux tarball URL has no numeric version: $url" >&2
    return 1
  }
  base=$(basename "${url%%\?*}")
  sha=$(awk -v b="$base" '
    function hex64(s,    m) {
      if (match(s, /(^|[^0-9A-Fa-f])[0-9A-Fa-f]{64}([^0-9A-Fa-f]|$)/)) {
        m = substr(s, RSTART, RLENGTH)
        gsub(/[^0-9A-Fa-f]/, "", m)
        if (length(m) == 64) {
          print tolower(m)
          return 0
        }
      }
      return 1
    }
    {
      if (!seen) {
        i = index($0, b)
        if (!i) next
        seen = 1
        if (hex64(substr($0, i + length(b))) == 0) { ok = 1; exit 0 }
        next
      }
      if (hex64($0) == 0) { ok = 1; exit 0 }
    }
    END { if (!ok) exit 1 }
  ' "$file") || {
    echo "no sha256 next to $base" >&2
    return 1
  }
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || {
    echo "no sha256 next to $base" >&2
    return 1
  }
  printf '%s\n' "$ver" "$url" "$sha" "$base"
}

# SHA-256 of a URL body. Caller already checked scheme and host.
company_sha256_url() {
  local url=$1 tmp sha
  tmp=$(mktemp)
  if ! company_fetch "$url" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  sha=$(sha256sum "$tmp" | awk '{print $1}')
  rm -f "$tmp"
  [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s\n' "$sha"
}

# SHA-256 from a sha256sum-format file for an exact basename.
company_sums_hash_for() {
  local sums_file=$1 want=$2
  local hash field
  while read -r hash field _; do
    [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]] || continue
    field="${field#\*}"
    field="${field##*/}"
    if [[ "$field" == "$want" ]]; then
      printf '%s\n' "$hash"
      return 0
    fi
  done <"$sums_file"
  return 1
}

# Print unique versions (capture group 1) found in a sums file, sort -V.
company_versions_from_sums() {
  local sums_file=$1 regex=$2
  local hash field base
  while read -r hash field _; do
    [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]] || continue
    field="${field#\*}"
    base="${field##*/}"
    if [[ "$base" =~ $regex ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done <"$sums_file" | sort -uV
}

company_fetch() {
  curl -fsSL "$1" -o "$2"
}

company_require_upstream() {
  local name=$1
  local up host sums_url sums_glob version_regex sums_host sums_format
  up=$(company_upstream_file "$name")
  [[ -f "$up" ]] || company_fail "$name: missing packages/$name/upstream"
  host=$(company_kv_get "$up" host) || true
  sums_url=$(company_kv_get "$up" sums_url) || true
  sums_glob=$(company_kv_get "$up" sums_glob) || true
  version_regex=$(company_kv_get "$up" version_regex) || true
  sums_host=$(company_kv_get "$up" sums_host) || true
  sums_format=$(company_sums_format "$up")
  case "$sums_format" in
    sha256sum|debian-packages|sha256-of-url|json-name-targz|studio-download-html) ;;
    *) company_fail "$name: sums_format must be sha256sum, debian-packages, sha256-of-url, json-name-targz, or studio-download-html (got $sums_format)" ;;
  esac
  [[ -n "$host" ]] || company_fail "$name: upstream missing host="
  [[ -n "$sums_url" ]] || company_fail "$name: upstream missing sums_url="
  [[ -n "$sums_glob" ]] || company_fail "$name: upstream missing sums_glob="
  [[ -n "$version_regex" ]] || company_fail "$name: upstream missing version_regex="
  company_valid_host "$host" || company_fail "$name: host= is not an FQDN: $host"
  if [[ -n "$sums_host" ]]; then
    company_valid_host "$sums_host" || company_fail "$name: sums_host= is not an FQDN: $sums_host"
  fi
  company_url_scheme_ok "$sums_url" || company_fail "$name: sums_url must be https:// (got $sums_url)"
  local sums_url_host
  sums_url_host=$(company_url_host "$sums_url")
  if [[ "$sums_url" == file://* ]]; then
    :
  else
    company_host_ok "$sums_url_host" "${sums_host:-$host}" || \
      company_fail "$name: sums_url host $sums_url_host is not ${sums_host:-$host}"
  fi
  [[ "$version_regex" == *"("* ]] || company_fail "$name: version_regex must have a capture group"
}

# Load allowlist, refuse path-traversal names, refuse extra package dirs.
# Sets company_pkgs array.
company_load_gate() {
  local name extra
  company_pkgs=()
  mapfile -t company_pkgs < <(company_allowlist)
  [[ ${#company_pkgs[@]} -gt 0 ]] || company_fail "allowlist empty"
  for name in "${company_pkgs[@]}"; do
    company_valid_pkgname "$name" || company_fail "allowlist name is not a pkgname: $name"
    [[ -f "$(company_pkgbuild_file "$name")" ]] || company_fail "no PKGBUILD for $name"
    company_require_upstream "$name"
  done
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    company_valid_pkgname "$name" || company_fail "packages/$name is not a pkgname"
    local listed=0
    for want in "${company_pkgs[@]}"; do
      if [[ "$want" == "$name" ]]; then
        listed=1
        break
      fi
    done
    [[ $listed -eq 1 ]] || company_fail "packages/$name is not in allowlist.txt"
  done < <(company_package_dirs)
}
