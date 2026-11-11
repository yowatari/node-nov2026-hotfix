# Shipping the Node.js November 2026 security releases without waiting for official images

English | [日本語](README.ja.md)

> Intended readers: people using Docker and GitHub Actions who wait for official image updates when a CVE drops.

On 2026-11-11 the Node.js project released **fixed versions of the 26.x, 24.x and 22.x lines (26.13.1 / 24.22.3 / 22.23.5)** ([announcement](https://nodejs.org/en/blog/vulnerability/november-2026-security-releases); highest severity: HIGH). This repository exists so that, once fixed versions are on nodejs.org, **bumping the version numbers and pushing** is all it takes to publish signed images with an SBOM (a bill of materials for the image) to ghcr.io. The pipeline now builds these fixed versions (the previous ones were 26.13.0 / 24.22.2 / 22.23.4).

## How it is built

| | What |
|---|---|
| Node.js | The **official binaries** from nodejs.org, repackaged as Wolfi apks with melange (no compilation) |
| Tamper check | **Verifies the GPG signature on `SHASUMS256.txt` against the Node.js releasers' keys**, then pins the tarballs to those sha256s |
| Images | Assembled with apko: runtime (`:24`, node only) / `-dev` (adds npm and a shell) |
| Distribution | Keyless cosign signatures, SBOM, and attached Trivy / Grype scan results |
| Scope | 26 / 24 / 22. End-of-life lines (20.x and older) get no official fix and are out of scope |

The official binaries are used because building Node from source takes tens of minutes per version and architecture, which defeats the point of shipping on release day. Wolfi is glibc-based, so the official linux binaries run as-is. The fix patches are only published together with the release, so there is no way to ship a patched build ahead of it either.

## On release day

1. Check that the fixed versions are on nodejs.org.

   ```sh
   curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.version | test("^v(26|24|22)\\."))] | group_by(.version | split(".")[0]) | map(.[0] | "\(.version) security=\(.security)") | .[]'
   ```

2. Bump `DEFAULT_VERSIONS` in `.github/workflows/build.yml` to the fixed versions and merge to main. `scripts/render.sh` takes care of the sha256s and signature verification.
3. To ship one version first, run the workflow via `workflow_dispatch` with `versions` set to JSON such as `["24.22.3"]`.

If `render.sh` stops with "not signed by an active Node.js releaser", the release may have been signed by a newly added releaser. Find a [nodejs/release-keys](https://github.com/nodejs/release-keys) commit that contains their key and bump `RELEASE_KEYS_REF` in `render.sh`.

## Usage

```sh
docker run --rm ghcr.io/yowatari/node-nov2026-hotfix:24 -v
```

The runtime image has neither a shell nor npm, so install dependencies in the `-dev` image and `COPY` the result across.

```dockerfile
FROM ghcr.io/yowatari/node-nov2026-hotfix:24-dev AS build
COPY --chown=65532:65532 package*.json ./
RUN npm ci --omit=dev
COPY --chown=65532:65532 . .

FROM ghcr.io/yowatari/node-nov2026-hotfix:24
COPY --from=build /app /app
CMD ["server.js"]
```

A minimal example is in [examples/copy-app](examples/copy-app).

### Tags

| Tag | Contents |
|---|---|
| `24`, `24.22.3`, `24.22.3-r0` | node only. uid 65532, no shell, `WORKDIR /app`, `NODE_ENV=production` |
| `24-dev`, `24.22.3-dev`, `24.22.3-r0-dev` | The above plus npm / npx (and corepack where bundled) and busybox |

26 and 22 follow the same pattern. All images are multi-arch: linux/amd64 and linux/arm64.

### Verifying the signature

```sh
cosign verify ghcr.io/yowatari/node-nov2026-hotfix:24 \
  --certificate-identity-regexp '^https://github.com/yowatari/node-nov2026-hotfix/.github/workflows/build.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## What this does not guarantee

- The payload is the Node.js project's official binary, unchanged. This repository adds source verification, a minimal base, signatures, an SBOM and scan results. What gets fixed in Node itself depends on the Node.js project's release.
- End-of-life lines (20.x and older) are not covered.
- Whether a vulnerability scanner reports the image as fixed depends on the scanner's data. The package has its own name (`node-hotfix`), so scan results are not proof of a fix. Check the version and the SBOM instead.
- This is a demo, so the images live on a personal account's ghcr (`yowatari`). For production use, fork the repository into your own organization. The workflow publishes to `ghcr.io/<repository name>`, so it works as is.

## Files

| Path | Contents |
|---|---|
| `scripts/render.sh` | Verifies the signature and renders the melange / apko configs and hashes for a version |
| `melange.tmpl.yaml` | Packages the official binary as `node-hotfix` / `node-hotfix-npm` apks, with tests |
| `apko.tmpl.yaml` | Image definition (runtime and `-dev`) |
| `scripts/smoke.sh` | Image smoke test (version, uid, no shell and no npm, HTTP response, npm in `-dev`) |
| `.github/workflows/build.yml` | Build, publish, sign and scan |

### Building locally

```sh
scripts/render.sh 24.22.3
docker run --rm -v "$PWD":/work -w /work cgr.dev/chainguard/melange keygen melange.rsa
docker run --privileged --rm -v "$PWD":/work -w /work cgr.dev/chainguard/melange \
  build build/24.22.3/melange.yaml --arch x86_64 --signing-key melange.rsa \
  --out-dir build/24.22.3/packages
docker run --privileged --rm -v "$PWD":/work -w /work cgr.dev/chainguard/melange \
  test build/24.22.3/melange.yaml --arch x86_64 \
  --repository-append /work/build/24.22.3/packages --keyring-append /work/melange.rsa.pub
docker run --rm -v "$PWD":/work -w /work cgr.dev/chainguard/apko \
  build build/24.22.3/apko.yaml node-hotfix:rt build/24.22.3/image-rt.tar --arch x86_64 \
  -r /work/build/24.22.3/packages -k /work/melange.rsa.pub   # apko-dev.yaml for -dev
docker load < build/24.22.3/image-rt.tar
scripts/smoke.sh node-hotfix:rt-amd64 node-hotfix:dev-amd64 24.22.3
```
