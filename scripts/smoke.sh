#!/usr/bin/env bash
# Usage: scripts/smoke.sh <runtime-image> <dev-image> <node-version> [platform]
# Checks the runtime image runs the expected Node as nonroot with no shell and
# no npm, that it serves HTTP, and that the -dev image has npm and a shell.
set -euo pipefail

rt="$1" dev="$2" version="$3"
plat=()
[ -n "${4:-}" ] && plat=(--platform "$4")

# For a multi-arch index pinned by digest, run the platform's own manifest:
# docker refuses to pull the same index digest a second time for another
# platform ("cannot overwrite digest").
resolve() {
  local ref="$1" platform="$2" digest
  if [ -z "$platform" ] || [[ "$ref" != *@sha256:* ]]; then echo "$ref"; return; fi
  local os="${platform%%/*}" arch="${platform#*/}"
  digest="$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' |
    jq -r --arg os "$os" --arg arch "$arch" \
      '.manifests[]? | select(.platform.os == $os and .platform.architecture == $arch) | .digest')"
  if [ -n "$digest" ]; then echo "${ref%@*}@$digest"; else echo "$ref"; fi
}
rt="$(resolve "$rt" "${4:-}")"
dev="$(resolve "$dev" "${4:-}")"

test "$(docker run --rm "${plat[@]}" "$rt" -v | tee /dev/stderr)" = "v$version"
docker run --rm "${plat[@]}" "$rt" -e '
  const fs = require("node:fs");
  if (process.getuid() !== 65532) throw new Error("uid " + process.getuid());
  for (const p of ["/bin/sh", "/usr/bin/npm", "/usr/lib/node_modules"])
    if (fs.existsSync(p)) throw new Error(p + " should not be in the runtime image");
'
if docker run --rm "${plat[@]}" --entrypoint /bin/sh "$rt" -c true > /dev/null 2>&1; then
  echo "runtime image has a shell" >&2; exit 1
fi

# The runtime image can serve HTTP (and does TLS crypto with its bundled OpenSSL).
name="smoke-node-$$"
docker run -d "${plat[@]}" --name "$name" "$rt" -e '
  require("node:crypto").randomBytes(16);
  require("node:http").createServer((q, s) => s.end("ok " + process.version)).listen(8080, () => console.log("listening"));
' > /dev/null
trap 'docker rm -f "$name" > /dev/null 2>&1 || true' EXIT
for _ in $(seq 1 20); do
  docker logs "$name" 2>&1 | grep -q listening && break
  sleep 1
done
test "$(docker exec "$name" /usr/bin/node -e '
  require("node:http").get("http://127.0.0.1:8080", r => { let b = ""; r.on("data", d => b += d); r.on("end", () => console.log(b)); });
')" = "ok v$version"

docker run --rm "${plat[@]}" --entrypoint /usr/bin/npm "$dev" --version
docker run --rm "${plat[@]}" --entrypoint /bin/sh "$dev" -c 'id -u | grep -qx 65532'
echo "smoke OK: $rt / $dev ${4:-}"
