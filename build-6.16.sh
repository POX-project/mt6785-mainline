#!/usr/bin/env bash
# Builds the begonia (arm64) kernel from the 6.16 branch of mt6785-mainline.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$here/build-begonia.sh" --out "${OUTDIR:-$here/out}" 6.16 "$@"