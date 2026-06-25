#!/usr/bin/env bash
#
# deploy.sh — build the WebAssembly bundle and deploy it to Cloudflare,
# served at https://quine.qubeworlds.com.
#
# Requirements in the environment:
#   - zig 0.16.0 on PATH (see ../init.sh)
#   - node/npx (wrangler is run via npx)
#   - CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID
#
# The deploy token can edit Worker scripts + upload assets, but cannot manage
# zone-level Worker routes. Cloudflare's account-level custom-domains API does
# work with it, so we attach quine.qubeworlds.com via that API rather than via
# wrangler's route handling (which is why wrangler.jsonc has no `routes`).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

HOSTNAME="quine.qubeworlds.com"
ZONE_NAME="qubeworlds.com"
SERVICE="quine"

: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"
: "${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID}"

echo "==> Building WebGL2 bundle (ReleaseSmall)"
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgl2

echo "==> Building WebGPU bundle (ReleaseSmall)"
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgpu

# Publish the runtime loader as /index.html; it auto-detects WebGPU and falls
# back to WebGL2 (override with ?render=webgl|webgpu). editor.html ships
# alongside it so /editor serves the app too (auto-trailing-slash asset routing).
cp web/index.html zig-out/web/index.html
cp web/editor.html zig-out/web/editor.html
# llms.txt — a concise orientation for LLMs, served at /llms.txt (llmstxt.org).
cp web/llms.txt zig-out/web/llms.txt

echo "==> Deploying Worker + assets"
npx --yes wrangler@latest deploy

echo "==> Binding custom domain ${HOSTNAME}"
ZONE_ID="$(curl -s -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"][0]["id"])')"

curl -s -X PUT \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains" \
  -d "{\"zone_id\":\"${ZONE_ID}\",\"hostname\":\"${HOSTNAME}\",\"service\":\"${SERVICE}\",\"environment\":\"production\"}" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("custom domain bound:" , d.get("success"), d.get("errors") or "")'

echo "==> Done: https://${HOSTNAME}/"
