#!/usr/bin/env bash
# Gate tests: N packages, extra dirs, host/hash, propose. No makepkg.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/pkg-lib.sh
source "$REPO/scripts/pkg-lib.sh"

PASS=0
FAIL=0
ok() { printf 'ok  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

expect_ok() {
  local msg=$1
  shift
  if "$@" >/tmp/cap-out 2>/tmp/cap-err; then
    ok "$msg"
  else
    bad "$msg (exit $?): $(tr '\n' ' ' </tmp/cap-err)"
  fi
}

expect_fail() {
  local msg=$1 needle=$2
  shift 2
  if "$@" >/tmp/cap-out 2>/tmp/cap-err; then
    bad "$msg (wanted failure)"
  elif [[ -n "$needle" ]] && ! grep -q "$needle" /tmp/cap-err; then
    bad "$msg (wanted '$needle' in stderr: $(tr '\n' ' ' </tmp/cap-err))"
  else
    ok "$msg"
  fi
}

if company_host_ok keepersecurity.com keepersecurity.com; then ok 'host exact'; else bad 'host exact'; fi
if company_host_ok download.keepersecurity.com keepersecurity.com; then ok 'host subdomain'; else bad 'host subdomain'; fi
if company_host_ok keepersecurity.com.evil.com keepersecurity.com; then bad 'host suffix injection'; else ok 'host suffix injection'; fi
if company_host_ok evilkeepersecurity.com keepersecurity.com; then bad 'host prefix injection'; else ok 'host prefix injection'; fi
if company_valid_pkgname keeper-password-manager; then ok 'pkgname ok'; else bad 'pkgname ok'; fi
if company_valid_pkgname '../etc'; then bad 'pkgname traversal'; else ok 'pkgname traversal'; fi
if company_valid_pkgname 'alpha'; then ok 'pkgname alpha'; else bad 'pkgname alpha'; fi

RS=$(mktemp -d)
printf 'https://github.com/example/repo/releases/latest/download\n' >"$RS/repo-server"
got=$(COMPANY_REPO_SERVER= company_repo_server "$RS" || true)
if [[ "$got" == 'https://github.com/example/repo/releases/latest/download' ]]; then
  ok 'repo-server file'
else
  bad "repo-server file: $got"
fi
got=$(COMPANY_REPO_SERVER='file:///tmp/repo' company_repo_server "$RS" || true)
if [[ "$got" == 'file:///tmp/repo' ]]; then
  ok 'COMPANY_REPO_SERVER overrides repo-server'
else
  bad "COMPANY_REPO_SERVER: $got"
fi
rm -rf "$RS"
EMPTY=$(mktemp -d)
if COMPANY_REPO_SERVER= company_repo_server "$EMPTY" >/dev/null 2>&1; then
  bad 'repo-server missing should fail'
else
  ok 'repo-server missing fails'
fi
rmdir "$EMPTY"

H64A=$(printf 'a%.0s' {1..64})
H64B=$(printf 'b%.0s' {1..64})
H64C=$(printf 'c%.0s' {1..64})
H64D=$(printf 'd%.0s' {1..64})

write_pkg() {
  local root=$1 name=$2 ver=$3 sha=$4 host=$5
  mkdir -p "$root/packages/$name" "$root/sums"
  cat >"$root/packages/$name/PKGBUILD" <<EOF
pkgname=$name
pkgver=$ver
pkgrel=1
arch=('x86_64')
source=("https://${host}/${name}_\${pkgver}.deb")
sha256sums=('$sha')
EOF
  cat >"$root/packages/$name/upstream" <<EOF
host=$host
sums_url=file://${root}/sums/${name}.txt
sums_glob=${name}_{pkgver}.deb
version_regex=${name}_([0-9.]+)\\.deb
EOF
}

write_allow() {
  local root=$1
  shift
  printf '%s\n' "$@" >"$root/allowlist.txt"
}

verify() {
  COMPANY_ALLOW_FILE_SUMS=1 COMPANY_ROOT="$1" bash "$REPO/scripts/verify-pkgbuild.sh"
}

propose() {
  COMPANY_ALLOW_FILE_SUMS=1 COMPANY_ROOT="$1" bash "$REPO/scripts/propose-update.sh" "${@:2}"
}

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

write_pkg "$FIX" alpha 1.0.0 "$H64A" vendor.example
write_pkg "$FIX" beta 2.0.0 "$H64C" other.example
printf '%s  %s\n' "$H64A" 'alpha_1.0.0.deb' "$H64B" 'alpha_1.2.0.deb' >"$FIX/sums/alpha.txt"
printf '%s  %s\n' "$H64C" 'beta_2.0.0.deb' >"$FIX/sums/beta.txt"
write_allow "$FIX" alpha beta

expect_ok 'two packages verify' verify "$FIX"

mkdir -p "$FIX/packages/evil"
write_pkg "$FIX" evil 0.1.0 "$H64D" evil.example
printf '%s  %s\n' "$H64D" 'evil_0.1.0.deb' >"$FIX/sums/evil.txt"
expect_fail 'extra package dir' 'not in allowlist' verify "$FIX"
rm -rf "$FIX/packages/evil"

cp "$FIX/packages/beta/upstream" "$FIX/packages/beta/upstream.bak"
rm -f "$FIX/packages/beta/upstream"
expect_fail 'missing upstream' 'missing packages/beta/upstream' verify "$FIX"
mv "$FIX/packages/beta/upstream.bak" "$FIX/packages/beta/upstream"

sed -i 's#https://vendor.example/#https://evil.example/#' "$FIX/packages/alpha/PKGBUILD"
expect_fail 'source host mismatch' 'source= host' verify "$FIX"
sed -i 's#https://evil.example/#https://vendor.example/#' "$FIX/packages/alpha/PKGBUILD"

sed -i "s/^sha256sums=.*/sha256sums=('$H64D')/" "$FIX/packages/alpha/PKGBUILD"
expect_fail 'hash mismatch' 'sha256' verify "$FIX"
sed -i "s/^sha256sums=.*/sha256sums=('$H64A')/" "$FIX/packages/alpha/PKGBUILD"

sed -i "s/^sha256sums=.*/sha256sums=('SKIP')/" "$FIX/packages/alpha/PKGBUILD"
expect_fail 'SKIP digest' '64-hex' verify "$FIX"
sed -i "s/^sha256sums=.*/sha256sums=('$H64A')/" "$FIX/packages/alpha/PKGBUILD"

sed -i 's#source=.*#source=("https://vendor.example/alpha_${pkgver}.deb" "https://vendor.example/extra.bin")#' "$FIX/packages/alpha/PKGBUILD"
expect_fail 'two source URLs' 'exactly one https' verify "$FIX"
write_pkg "$FIX" alpha 1.0.0 "$H64A" vendor.example

printf '../etc\nalpha\nbeta\n' >"$FIX/allowlist.txt"
expect_fail 'path traversal allowlist' 'not a pkgname' verify "$FIX"
write_allow "$FIX" alpha beta

expect_ok 'two packages still verify' verify "$FIX"

expect_ok 'propose alpha only' propose "$FIX" alpha
if grep -q '^pkgver=1.2.0$' "$FIX/packages/alpha/PKGBUILD"; then
  ok 'alpha bumped to 1.2.0'
else
  bad "alpha pkgver=$(company_pkgbuild_get "$FIX/packages/alpha/PKGBUILD" pkgver)"
fi
if grep -q "sha256sums=('$H64B')" "$FIX/packages/alpha/PKGBUILD"; then
  ok 'alpha sha follows vendor latest'
else
  bad 'alpha sha not latest'
fi
if grep -q '^pkgver=2.0.0$' "$FIX/packages/beta/PKGBUILD"; then
  ok 'beta unchanged by alpha propose'
else
  bad 'beta was rewritten'
fi

sed -i "s/^sha256sums=.*/sha256sums=('$H64B')/" "$FIX/packages/alpha/PKGBUILD"
expect_ok 'verify after propose' verify "$FIX"

expect_ok 'propose all current' propose "$FIX"
if grep -q 'CURRENT alpha 1.2.0' /tmp/cap-out && grep -q 'CURRENT beta 2.0.0' /tmp/cap-out; then
  ok 'propose all reports CURRENT'
else
  bad "propose all output: $(tr '\n' ' ' </tmp/cap-out)"
fi

write_deb_pkg() {
  local root=$1 name=$2 ver=$3 sha=$4 host=$5
  mkdir -p "$root/packages/$name" "$root/sums"
  cat >"$root/packages/$name/PKGBUILD" <<EOF
pkgname=$name
pkgver=$ver
pkgrel=1
arch=('x86_64')
source=("https://${host}/${name}-\${pkgver}-amd64.deb")
sha256sums=('$sha')
EOF
  cat >"$root/packages/$name/upstream" <<EOF
host=$host
sums_host=index.example
sums_url=file://${root}/sums/${name}.packages
sums_format=debian-packages
sums_glob=${name}_{pkgver}_amd64.deb
version_regex=${name}_([0-9.]+)_amd64\\.deb
EOF
}

write_deb_packages() {
  local file=$1
  shift
  : >"$file"
  while [[ $# -ge 3 ]]; do
    local ver=$1 sha=$2 fn=$3
    shift 3
    cat >>"$file" <<EOF
Package: slack-desktop
Filename: pool/jessie/main/s/x/${fn}
SHA256: ${sha}

EOF
  done
}

DEB=$(mktemp -d)
write_deb_pkg "$DEB" gamma 4.50.0 "$H64A" downloads.slack-edge.com
write_deb_packages "$DEB/sums/gamma.packages" \
  4.50.0 "$H64A" 'gamma_4.50.0_amd64.deb' \
  4.52.155 "$H64B" 'gamma_4.52.155_amd64.deb'
write_allow "$DEB" gamma

expect_ok 'debian-packages verify' verify "$DEB"

sed -i "s/^sha256sums=.*/sha256sums=('$H64D')/" "$DEB/packages/gamma/PKGBUILD"
expect_fail 'debian-packages hash mismatch' 'sha256' verify "$DEB"
sed -i "s/^sha256sums=.*/sha256sums=('$H64A')/" "$DEB/packages/gamma/PKGBUILD"

expect_ok 'debian-packages propose' propose "$DEB" gamma
if grep -q '^pkgver=4.52.155$' "$DEB/packages/gamma/PKGBUILD"; then
  ok 'debian-packages bumped to 4.52.155'
else
  bad "gamma pkgver=$(company_pkgbuild_get "$DEB/packages/gamma/PKGBUILD" pkgver)"
fi
if grep -q "sha256sums=('$H64B')" "$DEB/packages/gamma/PKGBUILD"; then
  ok 'debian-packages sha follows Packages SHA256'
else
  bad 'debian-packages sha not latest'
fi

sed -i 's/^sums_format=.*/sums_format=nope/' "$DEB/packages/gamma/upstream"
expect_fail 'unknown sums_format' 'sums_format' verify "$DEB"
rm -rf "$DEB"

ART=$(mktemp -d)
mkdir -p "$ART/sums"
printf 'brother-rpm-body\n' >"$ART/sums/delta_1.0.bin"
ART_SHA=$(sha256sum "$ART/sums/delta_1.0.bin" | awk '{print $1}')
mkdir -p "$ART/packages/delta"
cat >"$ART/packages/delta/PKGBUILD" <<EOF
pkgname=delta
pkgver=1.0
pkgrel=1
arch=('x86_64')
source=("https://download.brother.com/welcome/delta_\${pkgver}.bin")
sha256sums=('$ART_SHA')
EOF
cat >"$ART/packages/delta/upstream" <<EOF
host=download.brother.com
sums_url=file://${ART}/sums/delta_1.0.bin
sums_format=sha256-of-url
sums_glob=delta_{pkgver}.bin
version_regex=delta_([0-9.]+)\\.bin
EOF
write_allow "$ART" delta
expect_ok 'sha256-of-url verify' verify "$ART"
sed -i "s/^sha256sums=.*/sha256sums=('$H64D')/" "$ART/packages/delta/PKGBUILD"
expect_fail 'sha256-of-url hash mismatch' 'sha256' verify "$ART"
rm -rf "$ART"

GK=$(mktemp -d)
mkdir -p "$GK/arts/0.9.0" "$GK/arts/1.2.0" "$GK/sums" "$GK/packages/gk"
printf 'old\n' >"$GK/arts/0.9.0/gitkraken-amd64.tar.gz"
printf 'new\n' >"$GK/arts/1.2.0/gitkraken-amd64.tar.gz"
GK_OLD=$(sha256sum "$GK/arts/0.9.0/gitkraken-amd64.tar.gz" | awk '{print $1}')
GK_NEW=$(sha256sum "$GK/arts/1.2.0/gitkraken-amd64.tar.gz" | awk '{print $1}')
printf '%s\n' "{\"name\":\"1.2.0\",\"url_targz\":\"file://${GK}/arts/1.2.0/gitkraken-amd64.tar.gz\"}" >"$GK/sums/gk.json"
cat >"$GK/packages/gk/PKGBUILD" <<EOF
pkgname=gk
pkgver=0.9.0
pkgrel=1
arch=('x86_64')
source=("https://vendor.example/gk-\${pkgver}.tar.gz")
sha256sums=('$GK_OLD')
EOF
cat >"$GK/packages/gk/upstream" <<EOF
host=vendor.example
sums_url=file://${GK}/sums/gk.json
sums_format=json-name-targz
sums_glob=gitkraken-amd64.tar.gz
version_regex="name":"([0-9.]+)"
EOF
write_allow "$GK" gk

sed -i 's/^sums_glob=.*/sums_glob=nope.tar.gz/' "$GK/packages/gk/upstream"
expect_fail 'json artifact basename' 'basename' verify "$GK"
sed -i 's/^sums_glob=.*/sums_glob=gitkraken-amd64.tar.gz/' "$GK/packages/gk/upstream"

printf '%s\n' '{"name":"1.2.0","url_targz":"file:///tmp/no-version-segment/gitkraken-amd64.tar.gz"}' >"$GK/sums/gk.json"
expect_fail 'json version missing from artifact URL' 'not found' verify "$GK"
printf '%s\n' "{\"name\":\"1.2.0\",\"url_targz\":\"file://${GK}/arts/1.2.0/gitkraken-amd64.tar.gz\"}" >"$GK/sums/gk.json"

expect_ok 'json-name-targz verify older pkgver' verify "$GK"
sed -i "s/^sha256sums=.*/sha256sums=('$H64D')/" "$GK/packages/gk/PKGBUILD"
expect_fail 'json-name-targz hash mismatch' 'sha256' verify "$GK"
sed -i "s/^sha256sums=.*/sha256sums=('$GK_OLD')/" "$GK/packages/gk/PKGBUILD"

expect_ok 'json-name-targz propose' propose "$GK" gk
if grep -q '^pkgver=1.2.0$' "$GK/packages/gk/PKGBUILD"; then
  ok 'json-name-targz bumped to 1.2.0'
else
  bad "gk pkgver=$(company_pkgbuild_get "$GK/packages/gk/PKGBUILD" pkgver)"
fi
if grep -q "sha256sums=('$GK_NEW')" "$GK/packages/gk/PKGBUILD"; then
  ok 'json-name-targz sha follows url_targz'
else
  bad 'json-name-targz sha not latest'
fi
expect_ok 'json-name-targz verify latest' verify "$GK"
rm -f "$GK/arts/1.2.0/gitkraken-amd64.tar.gz"
expect_ok 'json-name-targz propose current skips artifact' propose "$GK" gk
if grep -q 'CURRENT gk 1.2.0' /tmp/cap-out; then
  ok 'json-name-targz reports CURRENT'
else
  bad "json propose current: $(tr '\n' ' ' </tmp/cap-out)"
fi
rm -rf "$GK"

GKH=$(mktemp -d)
mkdir -p "$GKH/packages/gk" "$GKH/sums"
printf '%s\n' '{"name":"1.0.0","url_targz":"https://evil.example/1.0.0/gitkraken-amd64.tar.gz"}' >"$GKH/sums/gk.json"
cat >"$GKH/packages/gk/PKGBUILD" <<EOF
pkgname=gk
pkgver=1.0.0
pkgrel=1
arch=('x86_64')
source=("https://vendor.example/gk-\${pkgver}.tar.gz")
sha256sums=('$H64A')
EOF
cat >"$GKH/packages/gk/upstream" <<EOF
host=vendor.example
sums_url=file://${GKH}/sums/gk.json
sums_format=json-name-targz
sums_glob=gitkraken-amd64.tar.gz
version_regex="name":"([0-9.]+)"
EOF
write_allow "$GKH" gk
expect_fail 'json artifact host mismatch' 'artifact host' verify "$GKH"
rm -rf "$GKH"

ST=$(mktemp -d)
mkdir -p "$ST/packages/studio"
cat >"$ST/page.html" <<EOF
<table>
<tr><td>deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef</td></tr>
<tr><td><button>android-studio-old-linux.tar.gz</button></td><td>$H64A</td></tr>
</table>
<a href="https://edgedl.me.gvt1.com/android/studio/ide-zips/1.2.0/android-studio-old-linux.tar.gz">download</a>
EOF
cat >"$ST/packages/studio/PKGBUILD" <<EOF
pkgname=studio
pkgver=1.2.0
pkgrel=1
_archive=android-studio-old-linux.tar.gz
arch=('x86_64')
source=("https://edgedl.me.gvt1.com/android/studio/ide-zips/\${pkgver}/\${_archive}")
sha256sums=('$H64A')
EOF
cat >"$ST/packages/studio/upstream" <<EOF
host=gvt1.com
sums_url=file://${ST}/page.html
sums_format=studio-download-html
sums_glob=android-studio-*-linux.tar.gz
version_regex=ide-zips/([0-9.]+)/android-studio-
EOF
write_allow "$ST" studio
expect_ok 'studio-download-html verify' verify "$ST"

sed -i "s/^sha256sums=.*/sha256sums=('$H64D')/" "$ST/packages/studio/PKGBUILD"
expect_fail 'studio-download-html hash mismatch' 'sha256' verify "$ST"
sed -i "s/^sha256sums=.*/sha256sums=('$H64A')/" "$ST/packages/studio/PKGBUILD"

sed -i 's/^_archive=.*/_archive=android-studio-nope-linux.tar.gz/' "$ST/packages/studio/PKGBUILD"
expect_fail 'studio source URL must match page' 'source URL' verify "$ST"
sed -i 's/^_archive=.*/_archive=android-studio-old-linux.tar.gz/' "$ST/packages/studio/PKGBUILD"

printf '%s\n' '<a href="https://edgedl.me.gvt1.com/android/studio/ide-zips/9.9.9/android-studio-other-linux.tar.gz">x</a>' >>"$ST/page.html"
expect_fail 'studio two linux URLs' 'one linux' verify "$ST"
sed -i '/9.9.9/d' "$ST/page.html"

expect_ok 'studio-download-html propose' propose "$ST" studio
if grep -q '^pkgver=1.2.0$' "$ST/packages/studio/PKGBUILD" && grep -q '^_archive=android-studio-old-linux.tar.gz$' "$ST/packages/studio/PKGBUILD"; then
  ok 'studio propose keeps current version'
else
  bad "studio propose rewrote current: $(tr '\n' ' ' <"$ST/packages/studio/PKGBUILD")"
fi

cat >"$ST/page.html" <<EOF
<button>android-studio-rabbit1-linux.tar.gz</button>
<td>$H64B</td>
<a href="https://edgedl.me.gvt1.com/android/studio/ide-zips/2026.2.1.8/android-studio-rabbit1-linux.tar.gz">download</a>
EOF
sed -i 's/^pkgrel=.*/pkgrel=3/' "$ST/packages/studio/PKGBUILD"
expect_ok 'studio-download-html propose bump' propose "$ST" studio
if grep -q '^pkgver=2026.2.1.8$' "$ST/packages/studio/PKGBUILD"; then
  ok 'studio bumped to 2026.2.1.8'
else
  bad "studio pkgver=$(company_pkgbuild_get "$ST/packages/studio/PKGBUILD" pkgver)"
fi
if grep -q '^_archive=android-studio-rabbit1-linux.tar.gz$' "$ST/packages/studio/PKGBUILD"; then
  ok 'studio _archive follows download page'
else
  bad 'studio _archive not updated'
fi
if grep -q "sha256sums=('$H64B')" "$ST/packages/studio/PKGBUILD"; then
  ok 'studio sha follows download page'
else
  bad 'studio sha not updated'
fi
if grep -q '^pkgrel=1$' "$ST/packages/studio/PKGBUILD"; then
  ok 'studio version bump resets pkgrel'
else
  bad 'studio pkgrel not reset'
fi
expect_ok 'studio-download-html verify latest' verify "$ST"
expect_ok 'studio-download-html propose current' propose "$ST" studio
if grep -q 'CURRENT studio 2026.2.1.8' /tmp/cap-out; then
  ok 'studio propose reports CURRENT'
else
  bad "studio propose current: $(tr '\n' ' ' </tmp/cap-out)"
fi

sed -i 's|edgedl.me.gvt1.com|evil.example|' "$ST/page.html"
expect_fail 'studio artifact host mismatch' 'artifact host' verify "$ST"
rm -rf "$ST"

expect_ok 'real allowlist PKGBUILDs' bash "$REPO/scripts/verify-pkgbuild.sh"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
