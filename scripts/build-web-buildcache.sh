#!/usr/bin/env bash
#
# build-web-buildcache.sh — (re)build the prebuilt web buildcache that init.sh
# restores from R2 (cdn.qubeworlds.com/build-tools), so a fresh Claude Code /
# CI session is warm: the Emscripten SDK plus the compiled Jolt **and QuickJS**
# objects, plus every fetched package (sokol, zphysics, quickjs-ng), already in
# ./zig-pkg and ./.zig-cache.
#
# It warms the builds so those artifacts land in the cache, then packages
# zig-pkg/ + .zig-cache/ into the split tarball + SHA256SUMS that
# `restore_wasm_buildcache` in init.sh knows how to fetch and reassemble.
#
# UPLOADING the result to R2 is a separate, credentialed step (it needs the
# Cloudflare token + account that init.sh deliberately does NOT carry). After
# running this, upload the listed files under the `build-tools/` prefix.
#
#   ./scripts/build-web-buildcache.sh         # -> dist/build-tools/{parts,SHA256SUMS}
#
# Why this matters now: adding QuickJS made quickjs-ng a build dependency. The
# *currently published* cache predates it, so a fresh session restores a
# zig-pkg/ without quickjs-ng and any build that links the `script` module would
# try to fetch it from the network. Regenerate + re-upload the cache so QuickJS
# is cached like Jolt.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ZIG="${ZIG:-$ROOT_DIR/.zig/zig}"
[ -x "$ZIG" ] || ZIG=zig

ARCH="$(uname -m)"
OS="linux" # the cache is x86_64-linux only (matches init.sh)
NAME="quine-wasm-buildcache-${ARCH}-${OS}.tar.xz"
OUT="${OUT:-$ROOT_DIR/dist/build-tools}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

say "Warming native + web builds so deps/objects are cached (emsdk, Jolt, QuickJS)"
"$ZIG" build # native: fetches deps, compiles Jolt + QuickJS natively
"$ZIG" build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgl2
"$ZIG" build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgpu

mkdir -p "$OUT"

say "Packaging zig-pkg/ + .zig-cache/ -> ${NAME}"
tar -C "$ROOT_DIR" -cJf "${OUT}/${NAME}" zig-pkg .zig-cache

say "Splitting into <300 MiB parts (R2 single-PUT limit): part00, part01, ..."
( cd "$OUT" && rm -f "${NAME}".part* && split -b 300m -d -a 2 "${NAME}" "${NAME}.part" )

say "Writing SHA256SUMS (parts + reassembled whole, as init.sh verifies)"
( cd "$OUT" && sha256sum "${NAME}" "${NAME}".part* > SHA256SUMS )

say "Done. Upload these to <CDN>/build-tools/ with your Cloudflare R2 credentials:"
( cd "$OUT" && ls -1 "${NAME}".part* SHA256SUMS | sed 's/^/    /' )
echo
echo "  init.sh fetches part00 + part01 + SHA256SUMS and reassembles. If the"
echo "  cache ever needs >2 parts, bump the 'for part in part00 part01' loop in"
echo "  init.sh's restore_wasm_buildcache to match."
