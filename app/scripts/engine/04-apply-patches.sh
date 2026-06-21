#!/bin/bash
set -eo pipefail

echo "==> Applying patches..."

KERNEL_TARGET=$(python3 -c '
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(sys.argv[1], "rb") as f:
    print(tomllib.load(f).get("kernel_target", ""))
' "$PROFILE_DIR/profile.toml")
KERNEL_PATCHVER=""

if [ -n "$KERNEL_TARGET" ]; then
    MK="$WORKTREE_DIR/target/linux/$KERNEL_TARGET/Makefile"
    if [ -f "$MK" ]; then
        KERNEL_PATCHVER=$(grep -oP 'KERNEL_PATCHVER\s*:=\s*\K[0-9]+\.[0-9]+' "$MK" | head -1)
    fi
fi

if [ -z "$KERNEL_PATCHVER" ]; then
    echo "Warning: Could not auto-detect kernel version. Guessing 6.12 or fallback."
    KERNEL_PATCHVER="6.12"
fi

if [ -d "$PROFILE_DIR/patches/kernel" ]; then
    for patch in "$PROFILE_DIR/patches/kernel/"*.patch; do
        [ -f "$patch" ] || continue
        dest="$WORKTREE_DIR/target/linux/$KERNEL_TARGET/patches-$KERNEL_PATCHVER/"
        mkdir -p "$dest"
        cp "$patch" "$dest"
        echo "Copied kernel patch: $(basename "$patch")"
    done
fi

if [ -d "$PROFILE_DIR/patches/source" ]; then
    for patch in "$PROFILE_DIR/patches/source/"*.patch; do
        [ -f "$patch" ] || continue
        if patch --dry-run -p1 -d "$WORKTREE_DIR" --silent < "$patch" 2>/dev/null; then
            patch -p1 -d "$WORKTREE_DIR" < "$patch"
            echo "Applied source patch: $(basename "$patch")"
        elif patch --dry-run -p1 -d "$WORKTREE_DIR" --reverse --silent < "$patch" 2>/dev/null; then
            echo "Already applied — skipping: $(basename "$patch")"
        else
            echo "ERROR: Cannot apply cleanly: $(basename "$patch")"
            echo "To fix interactively:"
            echo "  docker compose exec builder bash"
            echo "  cd /builder/source/worktrees/$PROFILE"
            echo "  quilt push -f       # force-apply up to the failing patch"
            echo "  # edit the reject files (.rej)"
            echo "  quilt refresh       # update the patch with your fixes"
            echo "  builder save-patches --profile $PROFILE"
            exit 1
        fi
    done
fi
