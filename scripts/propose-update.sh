#!/usr/bin/env bash
# Bump packages/<name>/PKGBUILD pkgver + sha256sums from that package's vendor
# checksums. Does not commit. Default: every allowlisted name.
#   scripts/propose-update.sh
#   scripts/propose-update.sh keeper-password-manager
set -euo pipefail
_HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pkg-lib.sh
source "$_HERE/pkg-lib.sh"

company_load_gate

in_allowlist() {
  local want=$1 n
  for n in "${company_pkgs[@]}"; do
    [[ "$n" == "$want" ]] && return 0
  done
  return 1
}

propose_json_name_targz() {
  local name=$1
  local pkg up sums_url sums_glob version_regex host tmp err reason body captured latest cur sha url art_host base want
  pkg=$(company_pkgbuild_file "$name")
  up=$(company_upstream_file "$name")
  sums_url=$(company_kv_get "$up" sums_url)
  sums_glob=$(company_kv_get "$up" sums_glob)
  version_regex=$(company_kv_get "$up" version_regex)
  host=$(company_kv_get "$up" host)
  tmp=$(mktemp)
  err=$(mktemp)
  company_fetch "$sums_url" "$tmp" || {
    rm -f "$tmp" "$err"
    company_fail "$name: could not fetch $sums_url"
  }
  body=$(tr -d '\n' <"$tmp")
  if [[ ! "$body" =~ $version_regex ]]; then
    rm -f "$tmp" "$err"
    company_fail "$name: version_regex did not match $sums_url"
  fi
  captured="${BASH_REMATCH[1]}"
  latest=$(company_json_name_targz_version "$tmp" 2>"$err") || {
    reason=$(tr '\n' ' ' <"$err")
    rm -f "$tmp" "$err"
    company_fail "$name: ${reason:-bad RELEASES JSON}"
  }
  if [[ "$captured" != "$latest" ]]; then
    rm -f "$tmp" "$err"
    company_fail "$name: version_regex captured $captured but JSON name is $latest"
  fi
  cur=$(company_pkgbuild_get "$pkg" pkgver)
  if [[ "$cur" == "$latest" ]]; then
    rm -f "$tmp" "$err"
    printf 'CURRENT %s %s\n' "$name" "$latest"
    return 0
  fi
  url=$(company_json_name_targz_url "$tmp" "" 2>"$err") || {
    reason=$(tr '\n' ' ' <"$err")
    rm -f "$tmp" "$err"
    company_fail "$name: ${reason:-bad RELEASES JSON}"
  }
  rm -f "$tmp" "$err"
  if [[ "$url" != file://* ]]; then
    art_host=$(company_url_host "$url")
    company_host_ok "$art_host" "$host" || company_fail "$name: artifact host $art_host is not $host"
  fi
  company_url_scheme_ok "$url" || company_fail "$name: artifact URL must be https:// (got $url)"
  base=$(basename "${url%%\?*}")
  want=$(company_expand_glob "$sums_glob" "$latest")
  [[ "$base" == "$want" ]] || company_fail "$name: artifact basename $base is not $want"
  sha=$(company_sha256_url "$url") || company_fail "$name: could not hash $url"
  [[ ${#sha} -eq 64 ]] || company_fail "$name: parse failed for $want"

  sed -i "s/^pkgver=.*/pkgver=$latest/" "$pkg"
  sed -i "s/^pkgrel=.*/pkgrel=1/" "$pkg"
  sed -i "s/^sha256sums=.*/sha256sums=('${sha,,}')/" "$pkg"

  printf 'UPDATED %s %s -> %s\n' "$name" "$cur" "$latest"
  printf 'next: git checkout -b bump-%s-%s && git add packages/%s/PKGBUILD && git commit && gh pr create\n' \
    "$name" "$latest" "$name"
}

propose_studio_download_html() {
  local name=$1
  local pkg up sums_url sums_glob version_regex host tmp err parsed reason body captured
  local ver url art_sha base art_host want cur cur_sha cur_archive src expanded rel
  pkg=$(company_pkgbuild_file "$name")
  up=$(company_upstream_file "$name")
  sums_url=$(company_kv_get "$up" sums_url)
  sums_glob=$(company_kv_get "$up" sums_glob)
  version_regex=$(company_kv_get "$up" version_regex)
  host=$(company_kv_get "$up" host)
  grep -q '^_archive=' "$pkg" || company_fail "$name: PKGBUILD missing _archive="
  tmp=$(mktemp)
  err=$(mktemp)
  parsed=$(mktemp)
  company_fetch "$sums_url" "$tmp" || {
    rm -f "$tmp" "$err" "$parsed"
    company_fail "$name: could not fetch $sums_url"
  }
  body=$(tr -d '\n' <"$tmp")
  if [[ ! "$body" =~ $version_regex ]]; then
    rm -f "$tmp" "$err" "$parsed"
    company_fail "$name: version_regex did not match $sums_url"
  fi
  captured="${BASH_REMATCH[1]}"
  if ! company_studio_download_linux "$tmp" >"$parsed" 2>"$err"; then
    reason=$(tr '\n' ' ' <"$err")
    rm -f "$tmp" "$err" "$parsed"
    company_fail "$name: ${reason:-bad Android Studio download page}"
  fi
  rm -f "$tmp"
  {
    read -r ver
    read -r url
    read -r art_sha
    read -r base
  } <"$parsed"
  rm -f "$parsed"
  [[ -n "$ver" && -n "$url" && -n "$art_sha" && -n "$base" ]] || {
    rm -f "$err"
    company_fail "$name: bad Android Studio download page"
  }
  if [[ "$captured" != "$ver" ]]; then
    rm -f "$err"
    company_fail "$name: version_regex captured $captured but download page version is $ver"
  fi
  if [[ "$url" != file://* ]]; then
    art_host=$(company_url_host "$url")
    company_host_ok "$art_host" "$host" || {
      rm -f "$err"
      company_fail "$name: artifact host $art_host is not $host"
    }
  fi
  company_url_scheme_ok "$url" || {
    rm -f "$err"
    company_fail "$name: artifact URL must be https:// (got $url)"
  }
  want=$(company_expand_glob "$sums_glob" "$ver")
  company_basename_matches_glob "$base" "$want" || {
    rm -f "$err"
    company_fail "$name: artifact basename $base is not $want"
  }
  mapfile -t src < <(company_source_urls "$pkg")
  if ! expanded=$(company_expand_pkg_url "$pkg" "${src[0]}" 2>"$err"); then
    reason=$(tr '\n' ' ' <"$err")
    rm -f "$err"
    company_fail "$name: ${reason:-could not expand source URL}"
  fi
  rm -f "$err"
  cur=$(company_pkgbuild_get "$pkg" pkgver)
  cur_sha=$(company_pkgbuild_get "$pkg" sha256sums)
  cur_archive=$(company_pkgbuild_get "$pkg" _archive)
  if [[ "$cur" == "$ver" && "${cur_sha,,}" == "$art_sha" && "$cur_archive" == "$base" && "$expanded" == "$url" ]]; then
    printf 'CURRENT %s %s\n' "$name" "$ver"
    return 0
  fi
  # Same version with a new slug or hash is a rebuild. A new version starts at pkgrel=1.
  if [[ "$cur" == "$ver" ]]; then
    rel=$(company_pkgbuild_get "$pkg" pkgrel)
    rel=$(( ${rel:-0} + 1 ))
  else
    rel=1
  fi
  sed -i "s/^pkgver=.*/pkgver=$ver/" "$pkg"
  sed -i "s/^pkgrel=.*/pkgrel=$rel/" "$pkg"
  sed -i "s/^_archive=.*/_archive=$base/" "$pkg"
  sed -i "s/^sha256sums=.*/sha256sums=('${art_sha}')/" "$pkg"
  printf 'UPDATED %s %s -> %s\n' "$name" "$cur" "$ver"
  printf 'next: git checkout -b bump-%s-%s && git add packages/%s/PKGBUILD && git commit && gh pr create\n' \
    "$name" "$ver" "$name"
}

propose_one() {
  local name=$1
  local pkg up sums_url sums_glob version_regex tmp latest cur sha want format norm url_base
  in_allowlist "$name" || company_fail "$name is not in allowlist.txt"
  pkg=$(company_pkgbuild_file "$name")
  up=$(company_upstream_file "$name")
  sums_url=$(company_kv_get "$up" sums_url)
  sums_glob=$(company_kv_get "$up" sums_glob)
  version_regex=$(company_kv_get "$up" version_regex)
  format=$(company_sums_format "$up")

  if [[ "$format" == json-name-targz ]]; then
    propose_json_name_targz "$name"
    return
  fi

  if [[ "$format" == studio-download-html ]]; then
    propose_studio_download_html "$name"
    return
  fi

  tmp=$(mktemp)
  company_fetch "$sums_url" "$tmp" || {
    rm -f "$tmp"
    company_fail "$name: could not fetch $sums_url"
  }
  local url_base
  url_base=$(basename "${sums_url%%\?*}")
  norm=$(mktemp)
  company_sums_as_sha256sum "$tmp" "$format" "$url_base" >"$norm" || {
    rm -f "$tmp" "$norm"
    company_fail "$name: unknown sums_format=$format"
  }
  rm -f "$tmp"
  latest=$(company_versions_from_sums "$norm" "$version_regex" | tail -n1)
  [[ -n "$latest" ]] || {
    rm -f "$norm"
    company_fail "$name: no versions matched version_regex in checksums"
  }
  want=$(company_expand_glob "$sums_glob" "$latest")
  sha=$(company_sums_hash_for "$norm" "$want") || {
    rm -f "$norm"
    company_fail "$name: latest $latest ($want) has no sha256 line"
  }
  rm -f "$norm"
  [[ ${#sha} -eq 64 ]] || company_fail "$name: parse failed for $want"

  cur=$(company_pkgbuild_get "$pkg" pkgver)
  if [[ "$cur" == "$latest" ]]; then
    printf 'CURRENT %s %s\n' "$name" "$latest"
    return 0
  fi

  sed -i "s/^pkgver=.*/pkgver=$latest/" "$pkg"
  sed -i "s/^pkgrel=.*/pkgrel=1/" "$pkg"
  sed -i "s/^sha256sums=.*/sha256sums=('${sha,,}')/" "$pkg"

  printf 'UPDATED %s %s -> %s\n' "$name" "$cur" "$latest"
  printf 'next: git checkout -b bump-%s-%s && git add packages/%s/PKGBUILD && git commit && gh pr create\n' \
    "$name" "$latest" "$name"
}

names=("$@")
if [[ ${#names[@]} -eq 0 ]]; then
  names=("${company_pkgs[@]}")
fi

for name in "${names[@]}"; do
  company_valid_pkgname "$name" || company_fail "not a pkgname: $name"
  propose_one "$name"
done
