#!/usr/bin/env bash
# Fail closed: allowlisted names have PKGBUILD + upstream; extra package dirs
# fail; each source= host and sha256 match that package's vendor checksums.
set -euo pipefail
_HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pkg-lib.sh
source "$_HERE/pkg-lib.sh"

company_load_gate

hostile() {
  local block=$1
  echo "$block" | grep -qE 'curl|\|[[:space:]]*bash|wget ' && return 0
  echo "$block" | grep -qE 'http://' && return 0
  return 1
}

# sums_format=json-name-targz: hash the tarball for this pkgver.
# Latest is "name"; a different pkgver swaps that path segment in url_targz.
verify_json_name_targz() {
  local name=$1 pkgver=$2 sha=$3 host=$4
  local up sums_url sums_glob version_regex tmp body captured latest url err reason art_host base want vendor
  up=$(company_upstream_file "$name")
  sums_url=$(company_kv_get "$up" sums_url)
  sums_glob=$(company_kv_get "$up" sums_glob)
  version_regex=$(company_kv_get "$up" version_regex)
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
  if ! url=$(company_json_name_targz_url "$tmp" "$pkgver" 2>"$err"); then
    reason=$(tr '\n' ' ' <"$err")
    rm -f "$tmp" "$err"
    company_fail "$name: ${reason:-bad RELEASES JSON}"
  fi
  rm -f "$tmp" "$err"
  if [[ "$url" != file://* ]]; then
    art_host=$(company_url_host "$url")
    company_host_ok "$art_host" "$host" || company_fail "$name: artifact host $art_host is not $host"
  fi
  company_url_scheme_ok "$url" || company_fail "$name: artifact URL must be https:// (got $url)"
  base=$(basename "${url%%\?*}")
  want=$(company_expand_glob "$sums_glob" "$pkgver")
  [[ "$base" == "$want" ]] || company_fail "$name: artifact basename $base is not $want"
  vendor=$(company_sha256_url "$url") || company_fail "$name: could not hash $url"
  [[ "${sha,,}" == "${vendor,,}" ]] || company_fail "$name: PKGBUILD sha256 $sha != vendor $vendor"
}

# sums_format=studio-download-html: version, URL, and sha256 come from the
# download page. PKGBUILD source= expands ${pkgver} and ${_archive} to that URL.
verify_studio_download_html() {
  local name=$1 pkgver=$2 sha=$3 host=$4
  local pkg up sums_url sums_glob version_regex tmp err parsed body captured
  local ver url art_sha base art_host want src expanded reason
  pkg=$(company_pkgbuild_file "$name")
  up=$(company_upstream_file "$name")
  sums_url=$(company_kv_get "$up" sums_url)
  sums_glob=$(company_kv_get "$up" sums_glob)
  version_regex=$(company_kv_get "$up" version_regex)
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
  rm -f "$tmp" "$err"
  {
    read -r ver
    read -r url
    read -r art_sha
    read -r base
  } <"$parsed"
  rm -f "$parsed"
  [[ -n "$ver" && -n "$url" && -n "$art_sha" && -n "$base" ]] || \
    company_fail "$name: bad Android Studio download page"
  if [[ "$captured" != "$ver" ]]; then
    company_fail "$name: version_regex captured $captured but download page version is $ver"
  fi
  [[ "$pkgver" == "$ver" ]] || company_fail "$name: pkgver $pkgver is not download page $ver"
  if [[ "$url" != file://* ]]; then
    art_host=$(company_url_host "$url")
    company_host_ok "$art_host" "$host" || company_fail "$name: artifact host $art_host is not $host"
  fi
  company_url_scheme_ok "$url" || company_fail "$name: artifact URL must be https:// (got $url)"
  want=$(company_expand_glob "$sums_glob" "$pkgver")
  company_basename_matches_glob "$base" "$want" || \
    company_fail "$name: artifact basename $base is not $want"
  [[ "${sha,,}" == "$art_sha" ]] || company_fail "$name: PKGBUILD sha256 $sha != vendor $art_sha"
  mapfile -t src < <(company_source_urls "$pkg")
  if ! expanded=$(company_expand_pkg_url "$pkg" "${src[0]}" 2>"$err"); then
    reason=$(tr '\n' ' ' <"$err")
    rm -f "$err"
    company_fail "$name: ${reason:-could not expand source URL}"
  fi
  rm -f "$err"
  [[ "$expanded" == "$url" ]] || company_fail "$name: source URL $expanded is not vendor $url"
}

verify_one() {
  local name=$1
  local pkg up host pkgver sha source_block url count src_host want vendor format
  pkg=$(company_pkgbuild_file "$name")
  up=$(company_upstream_file "$name")
  host=$(company_kv_get "$up" host)
  format=$(company_sums_format "$up")

  pkgver=$(company_pkgbuild_get "$pkg" pkgver)
  sha=$(company_pkgbuild_get "$pkg" sha256sums)
  [[ -n "$pkgver" ]] || company_fail "$name: missing pkgver="
  [[ "$pkgver" != "0.0.0" ]] || company_fail "$name: pkgver still placeholder — run scripts/propose-update.sh $name"
  [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || company_fail "$name: sha256sums must be exactly one 64-hex digest (not SKIP)"

  mapfile -t urls < <(company_source_urls "$pkg")
  count=${#urls[@]}
  [[ "$count" -eq 1 ]] || company_fail "$name: expected exactly one https source= URL, found $count"
  url=${urls[0]}
  src_host=$(company_url_host "$url")
  company_host_ok "$src_host" "$host" || company_fail "$name: source= host $src_host is not $host"

  source_block=$(awk '/^source=/, /\)/' "$pkg")
  hostile "$source_block" && company_fail "$name: source= looks hostile"

  if [[ "$format" == json-name-targz ]]; then
    verify_json_name_targz "$name" "$pkgver" "$sha" "$host"
    printf 'OK %s %s sha256=%s\n' "$name" "$pkgver" "${sha,,}"
    return
  fi

  if [[ "$format" == studio-download-html ]]; then
    verify_studio_download_html "$name" "$pkgver" "$sha" "$host"
    printf 'OK %s %s sha256=%s\n' "$name" "$pkgver" "${sha,,}"
    return
  fi

  local sums_url sums_glob tmp
  sums_url=$(company_kv_get "$up" sums_url)
  sums_glob=$(company_kv_get "$up" sums_glob)
  tmp=$(mktemp)
  company_fetch "$sums_url" "$tmp" || {
    rm -f "$tmp"
    company_fail "$name: could not fetch $sums_url"
  }
  local norm want
  want=$(company_expand_glob "$sums_glob" "$pkgver")
  norm=$(mktemp)
  company_sums_as_sha256sum "$tmp" "$format" "$want" >"$norm" || {
    rm -f "$tmp" "$norm"
    company_fail "$name: unknown sums_format=$format"
  }
  rm -f "$tmp"
  vendor=$(company_sums_hash_for "$norm" "$want") || {
    rm -f "$norm"
    company_fail "$name: version $pkgver ($want) not in vendor checksums"
  }
  rm -f "$norm"
  [[ "${sha,,}" == "${vendor,,}" ]] || company_fail "$name: PKGBUILD sha256 $sha != vendor $vendor"

  printf 'OK %s %s sha256=%s\n' "$name" "$pkgver" "${sha,,}"
}

for name in "${company_pkgs[@]}"; do
  verify_one "$name"
done
