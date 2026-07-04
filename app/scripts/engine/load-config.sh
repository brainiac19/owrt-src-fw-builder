#!/bin/bash
set -eo pipefail

echo "==> Loading configuration..."

rm -f "$WORKTREE_DIR/.config"

if [ -f "$PROFILE_DIR/config.seed" ]; then
    cat "$PROFILE_DIR/config.seed" >> "$WORKTREE_DIR/.config"
fi

python3 -c '
import sys, os
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)

packages = set(config.get("packages", []))
exclude = set(config.get("exclude_packages", []))

builder_root = sys.argv[2]
for s in config.get("shared_uci_defaults", []):
    deps_file = os.path.join(builder_root, "shared", "uci-defaults", f"{s}.deps")
    if os.path.exists(deps_file):
        with open(deps_file, "r") as df:
            for line in df:
                line = line.split("#")[0].strip()
                if line and line not in exclude:
                    packages.add(line)

for pkg in sorted(packages - exclude):
    print(f"CONFIG_PACKAGE_{pkg}=y")
for pkg in sorted(exclude):
    print(f"# CONFIG_PACKAGE_{pkg} is not set")
' "$PROFILE_DIR/profile.toml" "$BUILDER_ROOT" >> "$WORKTREE_DIR/.config"

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
