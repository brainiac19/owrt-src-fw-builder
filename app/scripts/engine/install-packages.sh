#!/bin/bash
set -eo pipefail

echo "==> Installing packages..."
cd "$WORKTREE_DIR"

# Use the native script to uninstall all existing feed symlinks robustly
./scripts/feeds uninstall -a

./scripts/feeds install -a

echo "==> Checking for pre-build package file conflicts..."
python3 "$BUILDER_ROOT/scripts/engine/check_pkg_conflicts.py" \
    "$WORKTREE_DIR" \
    "$PROFILE_DIR/profile.toml"
