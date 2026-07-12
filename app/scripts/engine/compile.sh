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
        -path "*/stamp/*" -type f \
        -exec touch {} + 2>/dev/null || true
    # build_dir stamps for toolchain and host targets
    find "$WORKTREE_DIR/build_dir/toolchain-"* "$WORKTREE_DIR/build_dir/host" \
        \( -name ".built" -o -name ".configured" -o -name ".prepared" \) \
        -exec touch {} + 2>/dev/null || true
    echo "==> Timestamps fixed."
fi
# ──────────────────────────────────────────────────────────────────────────────

# Apply ccache max size — configurable via CCACHE_MAX_SIZE env var
export CCACHE_DIR="/builder/ccache"
export CONFIG_CCACHE_DIR="/builder/ccache"
ccache -M "${CCACHE_MAX_SIZE:-20G}"
echo "ccache max size: $(ccache -p | grep max_size | awk '{print $NF}')"

echo "==> ccache stats before build:"
ccache -s || true


# ── Vermagic override authoritative setup ─────────────────────────────────────
export OVERRIDE_VERMAGIC=""
if [ -n "$PROFILE_DIR" ] && [ -f "$PROFILE_DIR/profile.toml" ]; then
    OVERRIDE_VERMAGIC=$(python3 -c '
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(sys.argv[1], "rb") as f:
    print(tomllib.load(f).get("vermagic", ""))
' "$PROFILE_DIR/profile.toml" 2>/dev/null || true)
fi

if [ -n "$OVERRIDE_VERMAGIC" ]; then
    echo "==> Vermagic override active: $OVERRIDE_VERMAGIC"

    # 1. Ensure include/kernel-defaults.mk in the worktree is patched with our recipe hook
    KDEFAULTS="$WORKTREE_DIR/include/kernel-defaults.mk"
    if [ -f "$KDEFAULTS" ]; then
        python3 -c '
import sys
path = sys.argv[1]
with open(path, "r") as f:
    c = f.read()
if "OVERRIDE_VERMAGIC" not in c:
    lines = c.split("\n")
    out = []
    for line in lines:
        out.append(line)
        if ".vermagic" in line and ">" in line:
            out.append("\t$(if $(OVERRIDE_VERMAGIC),printf \x27%s\x27 \x27$(OVERRIDE_VERMAGIC)\x27 > $(LINUX_DIR)/.vermagic)")
    with open(path, "w") as f:
        f.write("\n".join(out))
    print("  Patched include/kernel-defaults.mk for OVERRIDE_VERMAGIC.")
' "$KDEFAULTS"
    fi

    # 2. Pre-write any existing .vermagic files across build_dir so make sees the override immediately
    while IFS= read -r -d '' vmfile; do
        printf '%s' "$OVERRIDE_VERMAGIC" > "$vmfile"
        echo "  Updated existing .vermagic: $vmfile"
    done < <(find "$WORKTREE_DIR/build_dir" -name ".vermagic" -print0 2>/dev/null)

    # 3. Clean stale kmod packages and packaging stamps so any selected kmod rebuilds against OVERRIDE_VERMAGIC
    echo "  Cleaning stale kmod packages to ensure consistent vermagic dependency across modules..."
    rm -f "$WORKTREE_DIR"/bin/targets/*/*/packages/kmod-*.apk "$WORKTREE_DIR"/bin/targets/*/*/packages/kmod-*.ipk 2>/dev/null || true
    rm -f "$WORKTREE_DIR"/staging_dir/packages/*/kmod-*.apk "$WORKTREE_DIR"/staging_dir/packages/*/kmod-*.ipk 2>/dev/null || true
    find "$WORKTREE_DIR/build_dir" -maxdepth 4 \( -name ".built" -o -name ".pkgdir" -o -name "*.installed" \) -path "*/gpio-button-hotplug*" -exec rm -rf {} + 2>/dev/null || true
    find "$WORKTREE_DIR/build_dir" -maxdepth 4 \( -name ".built" -o -name ".pkgdir" -o -name "*.installed" \) -path "*/nft-fullcone*" -exec rm -rf {} + 2>/dev/null || true
fi
# ──────────────────────────────────────────────────────────────────────────────

echo "Compiling firmware using $(nproc) cores..."
MAKE_ARGS=("DL_DIR=/builder/dl" "CONFIG_CCACHE_DIR=/builder/ccache")
[ -n "$OVERRIDE_VERMAGIC" ] && MAKE_ARGS+=("OVERRIDE_VERMAGIC=$OVERRIDE_VERMAGIC")

if ! make -j"$(nproc)" "${MAKE_ARGS[@]}" 2>&1 | python3 "$BUILDER_ROOT/scripts/engine/filter_logs.py"; then
    if [[ "$FALLBACK_SINGLE_CORE" == "1" ]]; then
        echo "==========================================================="
        echo "Build failed with $(nproc) cores! Falling back to single core..."
        echo "==========================================================="
        if ! make -C "$WORKTREE_DIR" -j1 V=s "${MAKE_ARGS[@]}" 2>&1 | python3 "$BUILDER_ROOT/scripts/engine/filter_logs.py"; then
            echo "==========================================================="
            echo "Single core build also failed!"
            echo "==========================================================="
            exit 1
        fi
    else
        echo "==========================================================="
        echo "Build failed!"
        echo "To debug, run this command inside the container to see verbose logs:"
        echo "make -C $WORKTREE_DIR -j1 V=s ${MAKE_ARGS[*]}"
        echo "==========================================================="
        exit 1
    fi
fi

echo "=== Build Process Finished ==="

# ── Vermagic verification ──────────────────────────────────────────────────────
if [ -n "$OVERRIDE_VERMAGIC" ]; then
    echo "==========================================================="
    echo "==> Vermagic verification against profile.toml ($OVERRIDE_VERMAGIC):"
    MISMATCH=0
    while IFS= read -r -d '' vmfile; do
        actual=$(cat "$vmfile" 2>/dev/null || echo "MISSING")
        if [ "$actual" = "$OVERRIDE_VERMAGIC" ]; then
            echo "  [OK] $vmfile = $actual"
        else
            echo "  [MISMATCH] $vmfile = '$actual' (expected '$OVERRIDE_VERMAGIC')"
            MISMATCH=$((MISMATCH + 1))
        fi
    done < <(find "$WORKTREE_DIR/build_dir" -name ".vermagic" -print0 2>/dev/null)
    if [ "$MISMATCH" -gt 0 ]; then
        echo "  WARNING: $MISMATCH .vermagic file(s) had a different value!"
    else
        echo "  SUCCESS: All .vermagic files match official hash $OVERRIDE_VERMAGIC"
    fi
    echo "==========================================================="
fi
# ─────────────────────────────────────────────────────────────────────────────

echo "==> ccache stats after build:"
ccache -s || true
