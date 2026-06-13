#!/bin/bash
# Compile config.bu -> config.ign.
# Keys/credentials live in configs/ and are pulled in via *_local directives,
# so --files-dir must point at this repo root.
#
# Usage: ./build.sh [input.bu] [output.ign]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-${SCRIPT_DIR}/config.bu}"
OUT="${2:-${SCRIPT_DIR}/config.ign}"
BUTANE_IMAGE="quay.io/coreos/butane"

if [ ! -f "$SRC" ]; then
    echo "build.sh: input not found: $SRC" >&2
    exit 1
fi

if command -v butane >/dev/null 2>&1; then
    # Native butane on PATH.
    butane --files-dir "$SCRIPT_DIR" --strict --pretty "$SRC" > "$OUT"
elif command -v podman >/dev/null 2>&1; then
    # Fall back to the containerized butane.
    podman run --rm -v "${SCRIPT_DIR}":/work:z "$BUTANE_IMAGE" \
        --files-dir /work --strict --pretty "/work/$(basename "$SRC")" > "$OUT"
else
    echo "build.sh: neither 'butane' nor 'podman' found" >&2
    exit 1
fi

echo "build.sh: wrote $OUT"
