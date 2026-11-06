#!/usr/bin/env bash
# Usage: scripts/render.sh <node-version>   e.g. scripts/render.sh 24.22.2
#
# Fetches SHASUMS256.txt for the release from nodejs.org, verifies its GPG
# signature against the Node.js release keys (nodejs/release-keys, pinned
# below), and renders build/<version>/:
#   melange.yaml, apko.yaml (node runtime), apko-dev.yaml (node + npm + shell)
# Prints shell-style KEY=VALUE lines (also appended to $GITHUB_OUTPUT in CI).
set -euo pipefail

version="${1:?usage: $0 <node-version>}"
version="${version#v}"
root="$(cd "$(dirname "$0")/.." && pwd)"
major="${version%%.*}"
out="$root/build/$version"

# Keyring of the people allowed to sign Node.js releases. Pinned to a commit
# so a change to the key list is a reviewed change here. If a release is
# signed by a newly added releaser, bump this to a release-keys commit that
# contains their key.
RELEASE_KEYS_REPO="${RELEASE_KEYS_REPO:-https://github.com/nodejs/release-keys}"
RELEASE_KEYS_REF="${RELEASE_KEYS_REF:-481637f813e912c4aa3622d7964ab426c97b8e8d}"
keys="$root/.cache/release-keys-$RELEASE_KEYS_REF"
if [ ! -f "$keys/gpg-only-active-keys/pubring.kbx" ]; then
  mkdir -p "$keys"
  git -C "$keys" init -q
  git -C "$keys" fetch -q --depth 1 "$RELEASE_KEYS_REPO" "$RELEASE_KEYS_REF"
  git -C "$keys" checkout -q FETCH_HEAD
fi

mkdir -p "$out"
dist="https://nodejs.org/dist/v${version}"
curl -fsSL -o "$out/SHASUMS256.txt" "$dist/SHASUMS256.txt"
curl -fsSL -o "$out/SHASUMS256.txt.sig" "$dist/SHASUMS256.txt.sig"
if ! signer="$(gpgv --keyring "$keys/gpg-only-active-keys/pubring.kbx" \
  "$out/SHASUMS256.txt.sig" "$out/SHASUMS256.txt" 2>&1)"; then
  echo "$signer" >&2
  echo "SHASUMS256.txt for v${version} is not signed by an active Node.js releaser" >&2
  exit 1
fi
signer="$(sed -n 's/.*Good signature from "\([^<"]*\) <.*/\1/p' <<< "$signer" | head -1 | sed 's/ *$//')"

sha() {
  local f="node-v${version}-linux-$1.tar.xz" s
  s="$(awk -v f="$f" '$2 == f { print $1 }' "$out/SHASUMS256.txt")"
  if [ -z "$s" ]; then echo "$f is not listed in SHASUMS256.txt" >&2; exit 1; fi
  echo "$s"
}
sha256_x64="$(sha x64)"
sha256_arm64="$(sha arm64)"

render() {
  sed -e "s/@@VERSION@@/${version}/g" -e "s/@@MAJOR@@/${major}/g" \
    -e "s/@@SHA256_X64@@/${sha256_x64}/g" -e "s/@@SHA256_ARM64@@/${sha256_arm64}/g" "$@"
}

render "$root/melange.tmpl.yaml" > "$out/melange.yaml"
# Two images from the same apk set: a node-only runtime, and a -dev image
# with npm and a shell for build stages.
render -e "/^# @@DEV_PACKAGES@@$/d" -e "s/@@FLAVOR_SUFFIX@@//" \
  "$root/apko.tmpl.yaml" > "$out/apko.yaml"
render -e "s|^# @@DEV_PACKAGES@@$|    - node-hotfix-npm=${version}-r0\n    - busybox|" \
  -e "s/@@FLAVOR_SUFFIX@@/-dev/" \
  "$root/apko.tmpl.yaml" > "$out/apko-dev.yaml"

# Content hashes for CI caching. melange_hash covers everything that feeds
# the apk build (the tarball shas are inside melange.yaml); image_hash adds
# the apko configs on top.
melange_hash="$(sha256sum "$out/melange.yaml" | cut -c1-16)"
image_hash="$( { echo "$melange_hash"; cat "$out/apko.yaml" "$out/apko-dev.yaml"; } | sha256sum | cut -c1-16)"

{
  echo "version=$version"
  echo "major=$major"
  echo "signed_by=$signer"
  echo "sha256_x64=$sha256_x64"
  echo "sha256_arm64=$sha256_arm64"
  echo "dir=build/$version"
  echo "melange_hash=$melange_hash"
  echo "image_hash=$image_hash"
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"
