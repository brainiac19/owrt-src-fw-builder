#!/bin/bash
set -eo pipefail

echo "==> Fetching source..."

# Parse TOML values using python to be robust against spacing and quotes
readarray -t TOML_VARS < <(python3 -c '
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)
print(config.get("repo", ""))
print(config.get("branch", ""))
' "$PROFILE_DIR/profile.toml")

REPO="${TOML_VARS[0]}"
BRANCH="${TOML_VARS[1]}"

if [ -z "$REPO" ] || [ -z "$BRANCH" ]; then
    echo "Error: Failed to parse repo or branch from $PROFILE_DIR/profile.toml"
    exit 1
fi

mkdir -p /builder/source/main /builder/source/worktrees
if [ ! -d "/builder/source/main/.git" ]; then
    echo "Cloning main source repository (shallow)..."
    git clone --depth=1 -b "$BRANCH" "$REPO" /builder/source/main
else
    if [[ $FRESH_SETUP -eq 1 ]]; then
        echo "Updating main source repository..."
        git -C /builder/source/main fetch --depth=1 origin "$BRANCH"
        git -C /builder/source/main reset --hard "origin/$BRANCH"
    fi
fi

if [ ! -d "$WORKTREE_DIR" ]; then
    echo "Creating worktree for $PROFILE..."
    git -C /builder/source/main worktree prune
    git -C /builder/source/main worktree add --detach "$WORKTREE_DIR" HEAD
else
    if [[ $FRESH_SETUP -eq 1 ]]; then
        echo "Resetting worktree..."
        # Fetching must be done on the main repository, not in the worktree directly.
        # Main repo fetch was already handled in the block above if FRESH_SETUP=1.
        git -C "$WORKTREE_DIR" reset --hard "origin/$BRANCH"
        git -C "$WORKTREE_DIR" clean -fdx
    fi
fi
