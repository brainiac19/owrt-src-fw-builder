#!/bin/bash
set -eo pipefail

echo "==> Loading configuration..."

rm -f "$WORKTREE_DIR/.config"

if [ -f "$PROFILE_DIR/config.seed" ]; then
    cat "$PROFILE_DIR/config.seed" >> "$WORKTREE_DIR/.config"
fi

python3 -c '
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)

for pkg in config.get("packages", []):
    print(f"CONFIG_PACKAGE_{pkg}=y")
for pkg in config.get("exclude_packages", []):
    print(f"# CONFIG_PACKAGE_{pkg} is not set")
' "$PROFILE_DIR/profile.toml" >> "$WORKTREE_DIR/.config"

if [ -d "$PROFILE_DIR/pkg-options" ]; then
    for conf in "$PROFILE_DIR/pkg-options/"*.conf; do
        [ -e "$conf" ] || continue
        cat "$conf" >> "$WORKTREE_DIR/.config"
    done
fi

if [ "$USE_CCACHE" = "1" ]; then
    echo "Enabling ccache..."
    # Dedup existing config entries
    sed -i '/CONFIG_DEVEL/d' "$WORKTREE_DIR/.config"
    sed -i '/CONFIG_CCACHE/d' "$WORKTREE_DIR/.config"
    
    # Append the configuration
    echo "CONFIG_DEVEL=y" >> "$WORKTREE_DIR/.config"
    echo "CONFIG_CCACHE=y" >> "$WORKTREE_DIR/.config"
    echo "CONFIG_CCACHE_DIR=\"/builder/ccache\"" >> "$WORKTREE_DIR/.config"
fi

cd "$WORKTREE_DIR"
make defconfig
