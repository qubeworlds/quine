#!/usr/bin/env sh
# Tier B scale check: a dense pile of N dynamic bodies, run at several thread
# counts. Reports throughput (the threading speedup), asserts the final position
# digest is identical across thread counts (Jolt stays bit-deterministic at
# scale), and surfaces the peak contact-table occupancy vs its 64-slot cap.
#
# Usage:  scripts/phys-scale.sh [bodies] [ticks]   # default 5000 120
set -eu

ZIG="${ZIG:-./.zig/zig}"
BIN=./zig-out/bin/phys-scale
# ReleaseFast for representative timings (Debug Jolt runs with asserts on).
# `install` puts the artifact in zig-out/bin so we can set env per invocation.
"$ZIG" build install -Doptimize=ReleaseFast >/dev/null 2>&1 || true
[ -x "$BIN" ] || { echo "missing $BIN — run: $ZIG build install -Doptimize=ReleaseFast" >&2; exit 2; }

BODIES="${1:-5000}"
TICKS="${2:-120}"
export QUINE_SCALE_BODIES="$BODIES" QUINE_SCALE_TICKS="$TICKS"
# Size the Jolt arrays generously for a dense pile so contacts aren't dropped.
export QUINE_PHYS_MAX_BODIES="$((BODIES + 64))"
export QUINE_PHYS_MAX_PAIRS="$((BODIES * 16))"
export QUINE_PHYS_MAX_CONTACTS="$((BODIES * 8))"

baseline=""
status=0
for n in 1 2 4 -1; do
  line=$(QUINE_PHYS_THREADS="$n" "$BIN")
  printf '%s\n' "$line"
  pos=$(printf '%s\n' "$line" | sed -n 's/.*pos=\([0-9a-f]*\).*/\1/p')
  if [ -z "$baseline" ]; then
    baseline="$pos"
  elif [ "$pos" != "$baseline" ]; then
    echo "DIVERGED at threads=$n (pos=$pos != baseline=$baseline)" >&2
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "OK: identical position digest across thread counts — deterministic at scale"
else
  echo "FAIL: thread count changed body positions at scale" >&2
fi
exit "$status"
