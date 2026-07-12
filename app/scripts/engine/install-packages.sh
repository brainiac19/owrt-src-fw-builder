#!/bin/bash
set -eo pipefail

echo "==> Installing packages..."
cd "$WORKTREE_DIR"

# Use the native script to uninstall all existing feed symlinks robustly
./scripts/feeds uninstall -a

./scripts/feeds install -a 2>&1 | python3 "$BUILDER_ROOT/scripts/engine/filter_logs.py"
