#!/usr/bin/env bash
#
# publish-sdk.sh — publish a VERSIONED, immutable engine + the @taluvi/quine web
# SDK to the public CDN (R2 `cdn-qubeworlds`, served at https://cdn.qubeworlds.com).
#
#   /engine/<version>/quine-webgl2.{js,wasm}   immutable engine bundle
#   /sdk/<version>/quine.js                     SDK ESM, version-baked to pin /engine/<version>/
#
# The SDK loads the engine from the CDN; this publishes both under one <version>
# (a git SHA by default) so they ship in lockstep. Unlike publish-cdn.sh, this does
# NOT touch the mutable /engine/ (prod latest) or /sdk/latest — it only writes the
# immutable versioned paths, so it is safe to run without promoting to production.
#
#   ./scripts/publish-sdk.sh             # version = git short SHA
#   ./scripts/publish-sdk.sh <version>   # explicit version
#
# Needs CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID. Expects a current web build in
# zig-out/web (run `zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall
# -Dgpu=webgl2` first), and pnpm for the SDK build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"
: "${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID}"

BUCKET="cdn-qubeworlds"
VERSION="${1:-$(git rev-parse --short HEAD)}"
echo "==> Publishing version: $VERSION"

put() { # put <key> <file> <content-type>
  echo "    $BUCKET/$1"
  npx --yes wrangler@latest r2 object put "$BUCKET/$1" --file="$2" --content-type="$3" --remote >/dev/null
}

# 1. Build the SDK with the version baked in (its default engine base becomes
#    /engine/<version>/, pinning the matching engine).
echo "==> Building @taluvi/quine (version $VERSION)"
( cd sdk && pnpm install --silent && QUINE_VERSION="$VERSION" pnpm build )

# 2. Versioned, immutable engine bundle.
if [ -f zig-out/web/quine-webgl2.wasm ]; then
  echo "==> Engine -> /engine/$VERSION/"
  put "engine/$VERSION/quine-webgl2.js"   zig-out/web/quine-webgl2.js   text/javascript
  put "engine/$VERSION/quine-webgl2.wasm" zig-out/web/quine-webgl2.wasm application/wasm
else
  echo "!! zig-out/web/quine-webgl2.wasm missing — build the web engine first; skipping engine."
fi

# 3. Versioned SDK ESM.
echo "==> SDK -> /sdk/$VERSION/"
put "sdk/$VERSION/quine.js" sdk/dist/index.js text/javascript

# 4. Mutable "latest" pointers (short cache so apps pick up new releases): a
#    manifest + a /sdk/latest/ alias. They point at the IMMUTABLE versioned
#    artifacts above, so caching the artifacts is still safe.
putc() { # put with a short cache-control (mutable pointer)
  echo "    $BUCKET/$1 (cache 60s)"
  npx --yes wrangler@latest r2 object put "$BUCKET/$1" --file="$2" --content-type="$3" --cache-control="public, max-age=60" --remote >/dev/null
}
echo "==> Latest pointers -> /manifest.json + /sdk/latest/"
MANIFEST="$(mktemp)"
cat > "$MANIFEST" <<JSON
{
  "version": "$VERSION",
  "engine": "https://cdn.qubeworlds.com/engine/$VERSION",
  "sdk": "https://cdn.qubeworlds.com/sdk/$VERSION/quine.js",
  "publishedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
putc "manifest.json"       "$MANIFEST"        application/json
putc "sdk/latest/quine.js" sdk/dist/index.js  text/javascript
rm -f "$MANIFEST"

echo "==> Done."
echo "    Manifest: https://cdn.qubeworlds.com/manifest.json"
echo "    SDK:      https://cdn.qubeworlds.com/sdk/$VERSION/quine.js  (latest: /sdk/latest/quine.js)"
echo "    Engine:   https://cdn.qubeworlds.com/engine/$VERSION/quine-webgl2.js"
