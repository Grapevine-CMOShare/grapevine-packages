# company-arch-packages

Laptop operators: **[QUICKSTART.md](QUICKSTART.md)**.

Signed **pacman** repo for vendor apps Arch does not ship. Packages: **Keeper Desktop**, **Slack Desktop** (official `.deb` wrappers), **Brother HL-L9310CDW** LPR + CUPS wrapper (official `.rpm` wrappers), **GitKraken** (official amd64 tarball; install layout from the AUR `gitkraken` recipe), and **Android Studio** (official linux tarball; install layout from the AUR `android-studio` recipe).

Sibling of `omarchy-policy-exception` (same parent directory). This is **not** AUR, Chaotic-AUR, Snap, or a second Omarchy.

```
Vendor publishes artifact + checksums file
        ↓
scripts/propose-update.sh (or nvchecker) opens one PR per package
        ↓
CI verify.yml: scripts/verify-pkgbuild.sh  (host + vendor hash, every allowlisted name)
        ↓
Human merges to main
        ↓
CI publish.yml: makepkg --sign + repo-add --sign
        → GitHub Release repo-<UTC>  (company.db + every .pkg.tar.zst + signatures)
        ↓
Laptop: scripts/enable-repo.sh && pacman -S <allowlisted names>
        Server = https://github.com/<org>/company-arch-packages/releases/latest/download
```

Nobody uploads packages from a laptop. A version-bump PR that merges is the publish. `workflow_dispatch` on **publish pacman repo** republishes the current PKGBUILD.

The bot never merges. The allowlist never grows without a human PR. Packages are **GPG-signed**; `[company]` uses `SigLevel = Required`. Never `TrustAll`.

## Layout

| Path | Role |
|---|---|
| `allowlist.txt` | Only these names may have a PKGBUILD. Extra `packages/*` dirs fail CI |
| `packages/<name>/PKGBUILD` | Wrapper (Keeper unpacks vendor `.deb`) |
| `packages/<name>/upstream` | Vendor `host`, checksums URL, filename glob, version regex; optional `sums_host`, `sums_format` |
| `scripts/init-signing-key.sh` | One-time GnuPG key; public half in `keys/` |
| `scripts/export-ci-secret.sh` | One-time: `gh secret set GPG_SECRET_KEY` |
| `scripts/propose-update.sh` | Bump `pkgver` / `sha256sums` from each package's checksums file |
| `scripts/verify-pkgbuild.sh` | Host + hash gate for every allowlisted name |
| `scripts/build-repo.sh` | `makepkg --nodeps --sign` + `repo-add --sign` → `repo/` (CI) |
| `scripts/enable-repo.sh` | `pacman-key --lsign-key` + `[company]` HTTPS include |
| `scripts/gen-nvchecker.sh` | Rebuild `nvchecker.toml` from every `upstream` file |
| `test/run.sh` | N-package gate tests (no makepkg) |
| `keys/company-arch-packages.asc` | Public signing key (commit after first keygen) |
| `repo/` | Built db + packages (gitignored; Actions publishes) |

## One-time: signing key into GitHub (not a package push)

On any machine with `gpg` and `gh` (this does **not** need Arch, and it does **not** upload `.pkg.tar.zst`):

```bash
./scripts/init-signing-key.sh
git add keys/company-arch-packages.asc keys/fingerprint.txt
git commit -m "chore: company pacman signing public key"
./scripts/export-ci-secret.sh --set
```

Repo secret **`GPG_SECRET_KEY`** is the armored private key. Optional **`GPG_PASSPHRASE`** only if you wrapped the key; `init-signing-key.sh` uses an empty passphrase.

Never commit `.gnupg/`. After this, merge to `main` is what publishes.

## GitHub Actions

| Workflow | When | Secrets | What |
|---|---|---|---|
| `verify.yml` | every PR + push to `main` | none | `test/run.sh` + `verify-pkgbuild.sh` (every package) |
| `propose-update.yml` | daily cron / manual | `GITHUB_TOKEN` | one bump PR per package; does not merge |
| `publish.yml` | push to `main` (PKGBUILD paths) / `workflow_dispatch` | `GPG_SECRET_KEY` | build, sign, GitHub Release `repo-<UTC>` |

PRs never see `GPG_SECRET_KEY`. Forks cannot publish.

**Anonymous GET:** `pacman` has no GitHub token. `Server = …/releases/latest/download` 404s on a **private** repo. Make this git **public** (the PKGBUILD is not secret; required reviews still gate merges). Process lock: [GITHUB-ENFORCEMENT.md](GITHUB-ENFORCEMENT.md).

## Each Omarchy laptop (after apply, with network)

```bash
sudo ../company-arch-packages/scripts/enable-repo.sh
sudo pacman -S keeper-password-manager slack-desktop gitkraken android-studio
```

`enable-repo.sh` infers `origin` and writes

`Server = https://github.com/<org>/company-arch-packages/releases/latest/download`

Local debug only (after a manual `build-repo.sh`):

```bash
sudo COMPANY_REPO_SERVER="file://$PWD/repo" ./scripts/enable-repo.sh
```

`pacman -Qm` stays empty (package is in `[company]`, so it is not foreign). The work-standard collector PASSes C-30 for this name only when it is **not** in `-Qm`. AUR/`yay` of the same name still FAILs.

Do **not** put this repo or `.pkg.tar.zst` on the day-one USB. That stick is ISO + cidata + the policy pack.

## Do not

| | Why |
|---|---|
| AUR / `yay` / `omarchy pkg aur add` | C-21 |
| `SigLevel = TrustAll` | C-08 |
| Chaotic-AUR | Unsigned mass AUR rebuild |
| Fork omarchy-pkgs | Distro factory |
| Auto-merge version bumps | Human gate |
| `gh release upload` from a laptop | That is what `publish.yml` is for |
| Sign on `pull_request` | Secret exfil from a fork PR |

## Adding another vendor app

Same human PR, all of:

1. `packages/<name>/PKGBUILD`
2. `packages/<name>/upstream` (`host`, `sums_url`, `sums_glob`, `version_regex`; optional `sums_host` if checksums are on another FQDN; optional `sums_format`)
3. Add the name to `allowlist.txt`

`sums_format` defaults to `sha256sum` (Keeper). Slack uses `debian-packages`: CI converts `Filename:` + `SHA256:` stanzas into the same hash check. Brother uses `sha256-of-url`: the vendor does not publish a checksums catalog, so CI downloads the official RPM at `sums_url` and requires PKGBUILD `sha256sums` to match that file. GitKraken uses `json-name-targz`: `sums_url` is a JSON object with `name` and `url_targz`. Verify hashes the tarball for the PKGBUILD version. Propose reads `name` and hashes `url_targz` when that version differs. Android Studio uses `studio-download-html`: `sums_url` is the official download page, which lists one linux tarball URL and its sha256. Propose rewrites `pkgver`, `_archive`, and `sha256sums`. The `source=` host prefix stays in the PKGBUILD.

CI fails names not on the list, `packages/*` dirs not on the list, missing `upstream`, `source=` host mismatch, and sha256 ≠ vendor checksums. Merge to `main` republishes the whole `[company]` db. The bot may later bump that PKGBUILD; it cannot add the name.
