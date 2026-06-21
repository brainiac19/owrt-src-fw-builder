#!/bin/bash
set -eo pipefail

echo "==> Compiling..."
cd "$WORKTREE_DIR"

# ── Toolchain cache restoration ────────────────────────────────────────────────
# When the toolchain was restored from GHCR, the extracted files carry the
# timestamps from when they were archived (older than the freshly cloned source).
# make(1) uses mtime comparisons: if source files are newer than stamps, it
# will try to rebuild the toolchain even though nothing has changed.
#
# Fix: touch all stamp files to "now" (after source timestamps). This is safe
# because the cache key (profile.toml + source SHA + toolchain.mk + feeds.conf)
# mathematically guarantees the cached toolchain matches the current sources.
# A mtime lie cannot cause a stale build — only an unnecessary rebuild could,
# and we are preventing exactly that.
if [ "${TOOLCHAIN_RESTORED:-false}" = "true" ]; then
    echo "==> Toolchain restored from cache — fixing timestamps..."
    # staging_dir stamps (toolchain and host)
    find "$WORKTREE_DIR/staging_dir/" \
        \( -name ".built" -o -name ".configured" -o -name ".prepared" \) \
        -exec touch {} +
    # build_dir stamps for toolchain targets
    find "$WORKTREE_DIR/build_dir/toolchain-"* \
        \( -name ".built" -o -name ".configured" -o -name ".prepared" \) \
        -exec touch {} + 2>/dev/null || true
    echo "==> Timestamps fixed."
fi
# ──────────────────────────────────────────────────────────────────────────────

# Apply ccache max size — configurable via CCACHE_MAX_SIZE env var
ccache -M "${CCACHE_MAX_SIZE:-20G}"
echo "ccache max size: $(ccache -p | grep max_size | awk '{print $NF}')"

mkdir -p /builder/dl
echo "Downloading package dependencies using $(nproc) cores..."
make download -j"$(nproc)" DL_DIR=/builder/dl 2>&1 | python3 "$BUILDER_ROOT/scripts/engine/filter_logs.py"

echo "Compiling firmware using $(nproc) cores..."
if ! make -j"$(nproc)" DL_DIR=/builder/dl 2>&1 | python3 "$BUILDER_ROOT/scripts/engine/filter_logs.py"; then
    if [[ "$FALLBACK_SINGLE_CORE" == "1" ]]; then
        echo "==========================================================="
        echo "Build failed with $(nproc) cores! Falling back to single core..."
        echo "==========================================================="
        if ! make -C "$WORKTREE_DIR" -j1 V=s DL_DIR=/builder/dl 2>&1 | python3 "$BUILDER_ROOT/scripts/engine/filter_logs.py"; then
            echo "==========================================================="
            echo "Single core build also failed!"
            echo "==========================================================="
            exit 1
        fi
    else
        echo "==========================================================="
        echo "Build failed!"
        echo "To debug, run this command inside the container to see verbose logs:"
        echo "make -C $WORKTREE_DIR -j1 V=s DL_DIR=/builder/dl"
        echo "==========================================================="
        exit 1
    fi
fi

echo "=== Build Process Finished ==="
