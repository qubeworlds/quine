#!/usr/bin/env bash
#
# init.sh — one-shot dev environment setup for the quine engine.
#
# Handles macOS, Linux, and Windows (via Git Bash / MSYS2). It:
#   1. Installs/pins the expected Zig toolchain into ./.zig (if not already
#      available on PATH at the right version).
#   2. Installs the native system libraries sokol needs to LINK on Linux
#      (X11/GL/ALSA dev packages). macOS and Windows need no extra system
#      packages — the required frameworks/libs ship with the OS/toolchain.
#
# Safe to re-run; each step is idempotent.
#
# After running, either use the printed `./.zig/zig` path or add it to PATH,
# then: `zig build run`.
set -euo pipefail

# Keep this in sync with build.zig.zon's .minimum_zig_version.
ZIG_VERSION="0.16.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIG_DIR="${ROOT_DIR}/.zig"

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

  case "$os" in
    linux) install_linux_system_libs ;;
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
}

main "$@"
