#!/usr/bin/env bash
#
# init.sh — one-shot dev environment setup for the quine engine.
#
# Handles macOS, Linux, and Windows (via Git Bash / MSYS2). It:
#   1. Installs/pins the expected Zig toolchain into ./.zig (if not already
#      available on PATH at the right version). On x86_64-linux it pulls a
#      prebuilt Zig from our CDN first, falling back to ziglang.org.
#   2. On x86_64-linux, restores a prebuilt *web* buildcache (the Emscripten
#      SDK + the compiled Jolt physics object) into ./zig-pkg and ./.zig-cache
#      so the first `zig build -Dtarget=wasm32-emscripten ...` is warm — no
#      336 MiB emsdk download and no sysroot-lib regeneration. This is what
#      makes a fresh Claude Code session productive in seconds.
#   3. Installs the native system libraries sokol needs to LINK on Linux
#      (X11/GL/ALSA dev packages). macOS and Windows need no extra system
#      packages — the required frameworks/libs ship with the OS/toolchain.
#
# Safe to re-run; each step is idempotent.
#
# Env toggles:
#   QUINE_CDN_BASE        override the CDN base URL (default cdn.qubeworlds.com)
#   QUINE_SKIP_CDN=1      ignore the CDN; download Zig straight from ziglang.org
#   QUINE_SKIP_WEB_CACHE=1  don't restore the prebuilt web buildcache
#
# After running, either use the printed `./.zig/zig` path or add it to PATH,
# then: `zig build run`.
set -euo pipefail

# Keep this in sync with build.zig.zon's .minimum_zig_version.
ZIG_VERSION="0.16.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIG_DIR="${ROOT_DIR}/.zig"

# Prebuilt build tools live in the public R2 bucket served at cdn.qubeworlds.com.
CDN_BASE="${QUINE_CDN_BASE:-https://cdn.qubeworlds.com/build-tools}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo "aarch64" ;;
    x86_64|amd64)  echo "x86_64" ;;
    *) die "unsupported CPU arch: $(uname -m)" ;;
  esac
}

have_correct_zig() {
  command -v zig >/dev/null 2>&1 && [ "$(zig version)" = "${ZIG_VERSION}" ]
}

# verify_sha <file> <expected_hex> — best effort: succeeds if it matches, or if
# no sha256 tool is available (we don't want a missing tool to block setup).
verify_sha() {
  local file="$1" want="$2" got=""
  if   command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$file" | awk '{print $1}')"
  elif command -v shasum    >/dev/null 2>&1; then got="$(shasum -a 256 "$file" | awk '{print $1}')"
  else warn "no sha256 tool found; skipping integrity check for $(basename "$file")"; return 0
  fi
  [ "$got" = "$want" ]
}

install_zig() {
  local os="$1" arch="$2"
  if have_correct_zig; then
    say "Zig ${ZIG_VERSION} already on PATH ($(command -v zig)); skipping download."
    return
  fi
  if [ -x "${ZIG_DIR}/zig" ] && [ "$(${ZIG_DIR}/zig version)" = "${ZIG_VERSION}" ]; then
    say "Zig ${ZIG_VERSION} already present in ${ZIG_DIR}; skipping download."
    return
  fi

  # Fast path: prebuilt Zig from our CDN (hosted for x86_64-linux only — the
  # platform Claude Code sessions run on). The CDN tarball extracts flat into
  # ${ZIG_DIR}. Any failure falls through to the ziglang.org download below.
  if [ "$os" = "linux" ] && [ "$arch" = "x86_64" ] && [ "${QUINE_SKIP_CDN:-0}" != "1" ]; then
    local cdn_url="${CDN_BASE}/zig-${ZIG_VERSION}-${arch}-${os}.tar.xz"
    say "Fetching prebuilt Zig ${ZIG_VERSION} from CDN ..."
    rm -rf "${ZIG_DIR}" && mkdir -p "${ZIG_DIR}"
    if curl -fsSL "$cdn_url" | tar -xJ -C "${ZIG_DIR}" \
       && [ -x "${ZIG_DIR}/zig" ] \
       && [ "$(${ZIG_DIR}/zig version 2>/dev/null)" = "${ZIG_VERSION}" ]; then
      say "Zig installed from CDN to ${ZIG_DIR}/zig"
      return
    fi
    warn "CDN Zig fetch failed/invalid — falling back to ziglang.org."
  fi

  local triple ext
  case "$os" in
    macos)   triple="${arch}-macos";   ext="tar.xz" ;;
    linux)   triple="${arch}-linux";   ext="tar.xz" ;;
    windows) triple="${arch}-windows"; ext="zip" ;;
  esac

  local url="https://ziglang.org/download/${ZIG_VERSION}/zig-${triple}-${ZIG_VERSION}.${ext}"
  say "Downloading Zig ${ZIG_VERSION} for ${triple} ..."
  rm -rf "${ZIG_DIR}" && mkdir -p "${ZIG_DIR}"
  local tmp; tmp="$(mktemp -d)"
  if [ "$ext" = "zip" ]; then
    curl -fsSL "$url" -o "${tmp}/zig.zip"
    unzip -q "${tmp}/zig.zip" -d "${tmp}"
    cp -R "${tmp}"/zig-*/* "${ZIG_DIR}/"
  else
    curl -fsSL "$url" | tar -xJ -C "${ZIG_DIR}" --strip-components=1
  fi
  rm -rf "${tmp}"
  "${ZIG_DIR}/zig" version >/dev/null || die "Zig install failed."
  say "Zig installed to ${ZIG_DIR}/zig"
}

# Restore the prebuilt web (wasm) buildcache from the CDN: the Emscripten SDK
# (~336 MiB download + generated sysroot libs) and the compiled Jolt object,
# unpacked into ./zig-pkg and ./.zig-cache. With these in place, the first
# `zig build -Dtarget=wasm32-emscripten ...` skips straight to compiling our
# own code. x86_64-linux only (the cache contains Linux toolchain binaries);
# everything here is best-effort and never aborts setup.
restore_wasm_buildcache() {
  local os="$1" arch="$2"
  if [ "${QUINE_SKIP_WEB_CACHE:-0}" = "1" ]; then
    say "QUINE_SKIP_WEB_CACHE=1 — skipping prebuilt web buildcache."
    return 0
  fi
  if [ "$os" != "linux" ] || [ "$arch" != "x86_64" ]; then
    say "Prebuilt web buildcache is x86_64-linux only — skipping on ${os}/${arch}."
    say "  (web builds still work; the first wasm build fetches emsdk from source.)"
    return 0
  fi
  if [ -d "${ROOT_DIR}/zig-pkg" ]; then
    say "zig-pkg/ already present — skipping web buildcache download."
    return 0
  fi

  local name="quine-wasm-buildcache-${arch}-${os}.tar.xz"
  say "Fetching prebuilt web buildcache (emsdk + compiled Jolt, ~423 MiB) ..."
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "${CDN_BASE}/SHA256SUMS" -o "${tmp}/SHA256SUMS" 2>/dev/null \
    || warn "could not fetch SHA256SUMS — continuing without integrity checks."

  # The tarball is split into <300 MiB parts (R2 single-PUT limit). Fetch and
  # verify each part, then reassemble.
  local ok=1 part want
  for part in part00 part01; do
    if ! curl -fSL "${CDN_BASE}/${name}.${part}" -o "${tmp}/${name}.${part}"; then
      warn "download of ${name}.${part} failed."; ok=0; break
    fi
    if [ -f "${tmp}/SHA256SUMS" ]; then
      want="$(awk -v f="${name}.${part}" '$2==f{print $1}' "${tmp}/SHA256SUMS")"
      if [ -n "$want" ] && ! verify_sha "${tmp}/${name}.${part}" "$want"; then
        warn "checksum mismatch on ${name}.${part}."; ok=0; break
      fi
    fi
  done
  if [ "$ok" != "1" ]; then
    warn "web buildcache unavailable — first wasm build will fetch emsdk from source."
    rm -rf "${tmp}"; return 0
  fi

  cat "${tmp}/${name}.part00" "${tmp}/${name}.part01" > "${tmp}/${name}"
  if [ -f "${tmp}/SHA256SUMS" ]; then
    want="$(awk -v f="${name}" '$2==f{print $1}' "${tmp}/SHA256SUMS")"
    if [ -n "$want" ] && ! verify_sha "${tmp}/${name}" "$want"; then
      warn "reassembled buildcache checksum mismatch — discarding."
      rm -rf "${tmp}"; return 0
    fi
  fi
  if ! tar -tJf "${tmp}/${name}" >/dev/null 2>&1; then
    warn "buildcache archive is not a valid tarball — discarding."
    rm -rf "${tmp}"; return 0
  fi

  say "Extracting web buildcache into ${ROOT_DIR} (zig-pkg/ + .zig-cache/) ..."
  tar -C "${ROOT_DIR}" -xJf "${tmp}/${name}"
  rm -rf "${tmp}"
  say "Web buildcache restored — 'zig build -Dtarget=wasm32-emscripten ...' is now warm."
}

install_linux_system_libs() {
  say "Installing Linux system libraries sokol needs to link (X11/GL/ALSA dev)..."
  local SUDO=""
  [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq
    $SUDO apt-get install -y \
      libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev libasound2-dev
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y \
      libX11-devel libXi-devel libXcursor-devel mesa-libGL-devel alsa-lib-devel
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -S --needed --noconfirm \
      libx11 libxi libxcursor mesa alsa-lib
  else
    warn "No known package manager (apt/dnf/pacman). Install the dev packages"
    warn "for libX11, libXi, libXcursor, libGL, and libasound manually."
  fi
}

main() {
  local os arch
  os="$(detect_os)"
  arch="$(detect_arch)"
  say "Detected ${os}/${arch}"

  install_zig "$os" "$arch"

  # Warm the web toolchain before the (native-only) system libs, so a headless
  # web session is ready even if apt is unavailable.
  restore_wasm_buildcache "$os" "$arch"

  case "$os" in
    linux)
      # Native (windowed) builds need these; web builds don't. Non-fatal so a
      # headless/web-only session isn't blocked when apt can't run.
      install_linux_system_libs || warn "native system libs not installed — windowed 'zig build run' may not link, but web/test builds are unaffected." ;;
    macos) say "macOS: Metal ships with the OS — no extra system packages needed." ;;
    windows) say "Windows: D3D11 libs ship with the toolchain — no extra packages needed." ;;
  esac

  local zig_bin="zig"
  have_correct_zig || zig_bin="${ZIG_DIR}/zig"

  echo
  say "Done. Next steps:"
  if [ "$zig_bin" != "zig" ]; then
    echo "    export PATH=\"${ZIG_DIR}:\$PATH\"   # or call ${zig_bin} directly"
  fi
  echo "    ${zig_bin} build run     # build + run the windowed triangle (native)"
  echo "    ${zig_bin} build test    # run headless core tests"
  echo "    ${zig_bin} build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgl2   # web build (warm)"
}

main "$@"
