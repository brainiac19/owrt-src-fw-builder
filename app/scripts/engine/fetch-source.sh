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
print(config.get("tag", ""))
print(config.get("commit", ""))
' "$PROFILE_DIR/profile.toml")

REPO="${TOML_VARS[0]}"
BRANCH="${TOML_VARS[1]}"
TAG="${TOML_VARS[2]}"
COMMIT="${TOML_VARS[3]}"

if [ -z "$REPO" ]; then
    echo "Error: Failed to parse repo from $PROFILE_DIR/profile.toml"
    exit 1
fi

if [ -n "$TAG" ] && [ -n "$COMMIT" ]; then
    echo "Error: 'tag' and 'commit' are mutually exclusive in $PROFILE_DIR/profile.toml"
    exit 1
fi

if [ -n "$COMMIT" ] && [ -z "$BRANCH" ]; then
    echo "Error: 'branch' is required when 'commit' is specified in $PROFILE_DIR/profile.toml"
    exit 1
fi

if [ -z "$TAG" ] && [ -z "$COMMIT" ] && [ -z "$BRANCH" ]; then
    echo "Error: 'branch' or 'tag' is required in $PROFILE_DIR/profile.toml"
    exit 1
fi

mkdir -p /builder/source/main /builder/source/worktrees
if [ ! -d "/builder/source/main/.git" ]; then
    rm -rf /builder/source/main || true
    if [ -n "$TAG" ]; then
        echo "Cloning main source repository by tag $TAG (shallow)..."
        git clone --depth=1 --branch "$TAG" "$REPO" /builder/source/main
    elif [ -n "$COMMIT" ]; then
        echo "Cloning main source repository branch $BRANCH and pinning to commit $COMMIT..."
        git clone --depth=1 -b "$BRANCH" "$REPO" /builder/source/main
        git -C /builder/source/main fetch --depth=1 origin "$COMMIT"
        git -C /builder/source/main reset --hard FETCH_HEAD
    else
        echo "Cloning main source repository branch $BRANCH (shallow)..."
        git clone --depth=1 -b "$BRANCH" "$REPO" /builder/source/main
    fi
else
    if [[ $FRESH_SETUP -eq 1 ]]; then
        echo "Updating main source repository..."
        if [ -n "$TAG" ]; then
            git -C /builder/source/main fetch --depth=1 origin "$TAG"
            git -C /builder/source/main reset --hard FETCH_HEAD
        elif [ -n "$COMMIT" ]; then
            git -C /builder/source/main fetch --depth=1 origin "$COMMIT"
            git -C /builder/source/main reset --hard FETCH_HEAD
        else
            git -C /builder/source/main fetch --depth=1 origin "$BRANCH"
            git -C /builder/source/main reset --hard "origin/$BRANCH"
        fi
    fi
fi

if [ ! -e "$WORKTREE_DIR/.git" ]; then
    echo "Creating worktree for $PROFILE..."
    rm -rf "$WORKTREE_DIR" || true
    git -C /builder/source/main worktree prune
    git -C /builder/source/main worktree add --detach "$WORKTREE_DIR" HEAD
else
    if [[ $FRESH_SETUP -eq 1 ]]; then
        echo "Resetting worktree..."
        TARGET_SHA="$(git -C /builder/source/main rev-parse HEAD)"
        git -C "$WORKTREE_DIR" reset --hard "$TARGET_SHA"
        git -C "$WORKTREE_DIR" clean -fdx
    fi
fi
