#!/usr/bin/env sh
# Tier B determinism gate: prove the threaded Jolt solver reproduces the
# single-threaded result bit-for-bit before switching the threaded default on.
#
# Jolt is init-once per process, so the worker count is fixed per run — we
# compare *separate processes* at different QUINE_PHYS_THREADS. With cross-
# platform determinism enabled (build.zig), Jolt's result must be independent of
# thread count; this script is the check. Equal `trace=` lines ⇒ pass.
#
# Usage:  scripts/phys-determinism.sh            # compares 0 vs 4 (default)
#         scripts/phys-determinism.sh 0 2 8 -1   # compares an arbitrary set
set -eu

ZIG="${ZIG:-./.zig/zig}"
BIN="./zig-out/bin/phys-determinism"

"$ZIG" build phys-determinism >/dev/null 2>&1 || "$ZIG" build install >/dev/null
# Ensure the binary exists (the step above runs it once; build it explicitly).
"$ZIG" build >/dev/null 2>&1 || true
[ -x "$BIN" ] || { echo "missing $BIN — run: $ZIG build" >&2; exit 2; }

set -- "${@:-}"
[ "$#" -gt 0 ] && [ -n "$1" ] || set -- 0 4

baseline=""
status=0
for n in "$@"; do
  line=$(QUINE_PHYS_THREADS="$n" "$BIN" 2>&1)
  trace=$(printf '%s\n' "$line" | sed -n 's/.*trace=\([0-9a-f]*\).*/\1/p')
  printf '%s\n' "$line"
  if [ -z "$baseline" ]; then
    baseline="$trace"
  elif [ "$trace" != "$baseline" ]; then
    echo "DIVERGED at threads=$n (trace=$trace != baseline=$baseline)" >&2
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "OK: identical trace across thread counts — threaded Jolt is deterministic"
else
  echo "FAIL: thread count changed the result — do NOT flip the threaded default" >&2
fi
exit "$status"
