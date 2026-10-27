# QUICKSTART

Signed `[company]` pacman repo for vendor apps Arch does not ship (Keeper, Slack, Brother HL-L9310CDW, GitKraken, Android Studio). **Not** AUR. Git is **public** so `pacman` can anonymous-GET Releases.

```bash
sudo ./scripts/enable-repo.sh
sudo pacman -S keeper-password-manager slack-desktop gitkraken android-studio
```

`Server=` is `https://github.com/lateralcoders/zute-packages/releases/latest/download`. Day-one USB copies only the enable kit (script + public key). Packages stay on GitHub, not the stick.

Bot opens version-bump PRs. A human merges. Merge publishes a signed Release. `SigLevel = Required`. Never `TrustAll`, never `yay`.

Add a name: `packages/<name>/PKGBUILD` + `upstream` + `allowlist.txt`, one human PR. Full notes: [README.md](README.md). Process: [GITHUB-ENFORCEMENT.md](GITHUB-ENFORCEMENT.md). Laptops: sibling `omarchy-policy-exception`.
