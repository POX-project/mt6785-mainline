#!/usr/bin/env bash
# Build the mt6785-mainline kernel (branches 7.1 / 6.16) for Xiaomi begonia (arm64).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$SCRIPT_DIR}"
BRANCHES=()
JOBS="${JOBS:-$(nproc)}"
OUTDIR="${OUTDIR:-$ROOT/out}"
DO_DEPS=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: build-begonia.sh [options] [branch...]

Builds arch/arm64 Image + device trees for Xiaomi begonia (MediaTek MT6785)
from the mt6785-mainline tree. Branches default to 7.1 and 6.16.

Options:
  --deps        install build dependencies via apt-get (needs root)
  -j N          parallel jobs (default: nproc)
  --out DIR     output root (default: <ROOT>/out)
  -h, --help    this text

Environment:
  ROOT          where the mt6785-* trees live (default: script directory)
  CROSS_COMPILE toolchain prefix (default: aarch64-linux-gnu-)
  USE_CCACHE    set to 0 to bypass ccache (default: 1 when ccache is present)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --deps) DO_DEPS=1; shift ;;
    -j) JOBS="$2"; shift 2 ;;
    --out) OUTDIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    7.1|6.16) BRANCHES+=("$1"); shift ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ "$JOBS" -gt 0 ] 2>/dev/null || die "invalid job count: $JOBS"
[ ${#BRANCHES[@]} -gt 0 ] || BRANCHES=("7.1" "6.16")

install_deps() {
  local pkgs=(build-essential bc bison flex libssl-dev libelf-dev
              device-tree-compiler cpio python3 rsync kmod)
  command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 ||
    pkgs+=(gcc-aarch64-linux-gnu)
  info "installing: ${pkgs[*]}"
  if [ "$(id -u)" -ne 0 ]; then
    die "--deps needs root; re-run with sudo"
  fi
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
}

select_toolchain() {
  CROSS_COMPILE="${CROSS_COMPILE-}"
  CACHE_PREFIX=""
  if [ -z "$CROSS_COMPILE" ] && [ -z "${LLVM:-}" ]; then
    if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
      CROSS_COMPILE=aarch64-linux-gnu-
    elif command -v clang >/dev/null 2>&1; then
      LLVM=1
    fi
  fi
  if [ -n "$CROSS_COMPILE" ]; then
    command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 ||
      die "CROSS_COMPILE=${CROSS_COMPILE} not found"
  elif [ -z "${LLVM:-}" ]; then
    die "no aarch64 toolchain: install gcc-aarch64-linux-gnu (or use --deps)"
  fi

  if [ "${USE_CCACHE:-1}" != "0" ] && command -v ccache >/dev/null 2>&1; then
    CACHE_PREFIX="ccache "
  fi
}

show_ccache() {
  command -v ccache >/dev/null 2>&1 || return 0
  ccache -s 2>/dev/null | sed 's/^/      /' || true
}

check_host_deps() {
  local missing=()
  local t
  for t in make flex bison bc cpio dtc python3 rsync; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    info "missing host tools: ${missing[*]}"
    die "install them, or re-run with --deps"
  fi
}

android_frag() {
  cat <<'EOF'
CONFIG_MMU=y
CONFIG_NET=y
CONFIG_UNIX=y
CONFIG_ANDROID_BINDER_IPC=m
CONFIG_ANDROID_BINDERFS=y
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
CONFIG_LOCALVERSION_AUTO=n
CONFIG_MODULE_SIG_ALL=n
CONFIG_MODULE_SIG_FORCE=n
CONFIG_DTB=y
CONFIG_ARCH_MEDIATEK=y
EOF
}

tree_version() {
  local mk="$1/Makefile"
  [ -f "$mk" ] || return 1
  local v p s
  v=$(sed -n 's/^VERSION = //p'      "$mk" | head -1)
  p=$(sed -n 's/^PATCHLEVEL = //p'   "$mk" | head -1)
  s=$(sed -n 's/^SUBLEVEL = //p'     "$mk" | head -1)
  printf '%s.%s.%s\n' "$v" "$p" "$s"
}

resolve_tree() {
  local branch="$1"
  if [ -d "$ROOT/mt6785-$branch" ]; then
    printf '%s\n' "$ROOT/mt6785-$branch"
    return 0
  fi
  if [ -f "$ROOT/Makefile" ] && [ -d "$ROOT/arch" ]; then
    printf '%s\n' "$ROOT"
    return 0
  fi
  return 1
}

build_one() {
  local branch="$1"
  local tree ob kdir cross
  tree="$(resolve_tree "$branch")" ||
    die "no kernel tree for $branch under $ROOT (looked for $ROOT/mt6785-$branch and a tree at $ROOT)"
  ob="$OUTDIR/$branch"
  kdir="$ob/kernel"
  cross="${CROSS_COMPILE:-}"
  local -a make_args=(ARCH=arm64 O="$kdir")

  [ -f "$tree/Makefile" ] || die "not a kernel tree: $tree"

  local tver
  tver="$(tree_version "$tree" 2>/dev/null || echo unknown)"
  case "$tver" in
    "$branch"|"$branch".*) ok "tree $tree is v$tver" ;;
    *) die "tree $tree is v$tver, but branch $branch was requested" ;;
  esac

  [ -n "$cross" ] && make_args+=(CROSS_COMPILE="${CACHE_PREFIX}${cross}")
  [ -n "${LLVM:-}" ] && make_args+=(LLVM=1)

  mkdir -p "$kdir"

  info "$branch: configuring (defconfig)"
  make -C "$tree" "${make_args[@]}" defconfig

  info "$branch: applying Android fragment"
  "$tree/scripts/config" --file "$kdir/.config" \
    --enable  MMU \
    --enable  NET \
    --enable  UNIX \
    --enable  ANDROID_BINDER_IPC \
    --enable  ANDROID_BINDERFS \
    --enable  IKCONFIG \
    --enable  IKCONFIG_PROC \
    --disable LOCALVERSION_AUTO \
    --disable MODULE_SIG_ALL \
    --disable MODULE_SIG_FORCE \
    --enable  DTB \
    --enable  ARCH_MEDIATEK

  make -C "$tree" "${make_args[@]}" olddefconfig

  local sym
  for sym in CONFIG_ARCH_MEDIATEK CONFIG_ANDROID_BINDER_IPC CONFIG_ANDROID_BINDERFS; do
    grep -qE "^${sym}=" "$kdir/.config" ||
      die "$branch: $sym did not survive olddefconfig (unsatisfied dependency?)"
    grep -E "^${sym}=" "$kdir/.config" | sed 's/^/      /'
  done

  info "$branch: building Image + dtbs with -j$JOBS"
  make -C "$tree" "${make_args[@]}" -j"$JOBS" Image dtbs

  local img="$kdir/arch/arm64/boot/Image"
  local dtsdir="$kdir/arch/arm64/boot/dts/mediatek"
  [ -f "$img" ] || die "$branch: no Image produced"

  mkdir -p "$ob"
  cp -f "$img" "$ob/Image"
  local dtb n=0
  for dtb in "$dtsdir"/mt6785-xiaomi-begonia*.dtb; do
    [ -f "$dtb" ] || continue
    cp -f "$dtb" "$ob/"
    ok "$(basename "$dtb")"
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || die "$branch: built no begonia DTBs (CONFIG_ARCH_MEDIATEK not enabled)"

  local ver
  ver=$(make -s -C "$tree" "${make_args[@]}" kernelversion)
  ok "$branch kernel $ver"
  [ -n "$CACHE_PREFIX" ] && show_ccache
  info "$branch artifacts: $ob"
}

[ "$DO_DEPS" -eq 1 ] && install_deps
check_host_deps
select_toolchain

info "trees under $ROOT, jobs=$JOBS"
if [ -n "${LLVM:-}" ]; then
  info "toolchain: clang ($(clang --version | head -1))"
else
  info "toolchain: ${CROSS_COMPILE}gcc ($(${CROSS_COMPILE}gcc -dumpversion))"
fi
if [ -n "$CACHE_PREFIX" ]; then
  info "ccache: enabled ($(ccache --version | head -1))"
else
  info "ccache: disabled"
fi

for b in "${BRANCHES[@]}"; do
  build_one "$b"
done

info "done"