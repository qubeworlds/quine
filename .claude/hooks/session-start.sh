#!/bin/bash
#
# SessionStart hook — prepare the Zig + WebAssembly toolchain so a fresh
# Claude Code on the web session can build, test, and deploy immediately.
#
# Delegates to ./init.sh, which on x86_64-linux pulls a prebuilt Zig and the
# web buildcache (Emscripten SDK + compiled Jolt) from cdn.qubeworlds.com so
# the first `zig build -Dtarget=wasm32-emscripten ...` is warm — no 336 MiB
# emsdk download and no sysroot-lib regeneration. init.sh is idempotent, so
# this is safe on resume/clear (it skips anything already present).
set -euo pipefail

# Only the remote (Claude Code on the web) container needs this; local machines
# run ./init.sh themselves, and the buildcache is x86_64-linux only.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"
./init.sh

# Put the vendored Zig on PATH for the rest of the session so `zig ...` works.
if [ -x "$CLAUDE_PROJECT_DIR/.zig/zig" ]; then
  echo "export PATH=\"$CLAUDE_PROJECT_DIR/.zig:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
