#!/bin/bash
set -eo pipefail

echo "==> Applying feeds..."
cp "$WORKTREE_DIR/feeds.conf.default" "$WORKTREE_DIR/feeds.conf"

python3 -c '
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib

with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)

with open(sys.argv[2], "r") as f:
    default_feeds = f.read()

with open(sys.argv[2], "w") as out:
    for feed in config.get("extra_feeds", []):
        out.write(feed + "\n")
    out.write(default_feeds)
' "$PROFILE_DIR/profile.toml" "$WORKTREE_DIR/feeds.conf"

cd "$WORKTREE_DIR"
./scripts/feeds update -a
