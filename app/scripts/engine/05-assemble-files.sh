#!/bin/bash
set -eo pipefail

echo "==> Assembling files..."

SHARED=$(python3 -c '
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)
for s in config.get("shared_uci_defaults", []):
    print(s)
' "$PROFILE_DIR/profile.toml" || true)

STAGING_DIR="$WORKTREE_DIR/files"
mkdir -p "$STAGING_DIR/etc/uci-defaults"

for s in $SHARED; do
    if [ -f "$BUILDER_ROOT/shared/uci-defaults/$s" ]; then
        cp "$BUILDER_ROOT/shared/uci-defaults/$s" "$STAGING_DIR/etc/uci-defaults/"
    fi
done

if [ -d "$PROFILE_DIR/files" ]; then
    cp -r "$PROFILE_DIR/files/"* "$STAGING_DIR/" 2>/dev/null || true
fi

if [ -d "/builder/uci-defaults-extra" ]; then
    cp -r /builder/uci-defaults-extra/* "$STAGING_DIR/etc/uci-defaults/" 2>/dev/null || true
fi
