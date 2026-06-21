#!/bin/bash
set -eo pipefail

echo "==> Downloading packages..."
cd "$WORKTREE_DIR"

mkdir -p /builder/dl
echo "Downloading package dependencies using $(nproc) cores..."
make download -j"$(nproc)" DL_DIR=/builder/dl 2>&1 | python3 "$BUILDER_ROOT/scripts/engine/filter_logs.py"
