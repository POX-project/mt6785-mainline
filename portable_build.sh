#!/usr/bin/env bash
#
# portable_build.sh - Builds Begonia 6.16 mainline kernel with portable LLVM 19 toolchain
# POX-project: Begonia (Redmi Note 8 Pro / MT6785)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NDK_TOOLCHAIN="/media/dev/work/flutter_dev/portable_sdk/android-sdk/ndk/28.0.12433566/toolchains/llvm/prebuilt/linux-x86_64/bin"
TOOLS_BIN="$SCRIPT_DIR/tools/bin"

if [ ! -d "$NDK_TOOLCHAIN" ]; then
    echo "[-] Error: Portable NDK toolchain not found at $NDK_TOOLCHAIN" >&2
    exit 1
fi

mkdir -p "$TOOLS_BIN"
export PATH="$TOOLS_BIN:$NDK_TOOLCHAIN:$PATH"

export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-txorav}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-POX-Mainline}"

JOBS="${1:-20}"
echo "[+] Starting Begonia 6.16 build using Clang $(clang --version | head -1) with -j$JOBS"

# Invoke build-begonia.sh with -j and output directory
"$SCRIPT_DIR/build-begonia.sh" --out "$SCRIPT_DIR/out" 6.16 -j "$JOBS"

# Package AnyKernel3 flashable zip
echo "[+] Packaging AnyKernel3 flashable zip..."
"$SCRIPT_DIR/pack-anykernel3.sh" 6.16 auto

echo ""
echo "=========================================================="
echo "  BEGONIA 6.16 MAINLINE BUILD COMPLETE"
echo "=========================================================="
ls -lh "$SCRIPT_DIR/out/6.16/Image"
ls -lh "$SCRIPT_DIR/out/6.16/"*.dtb
ls -lh "$SCRIPT_DIR/out/"*.zip
echo "=========================================================="
