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

NEW_HASH="$(sha256sum "$WORKTREE_DIR/feeds.conf" | awk '{print $1}')"
OLD_HASH=""
if [ -f "$WORKTREE_DIR/.feeds.conf.hash" ]; then
    OLD_HASH="$(cat "$WORKTREE_DIR/.feeds.conf.hash")"
fi

FORCE_CLEAN=0
if [[ $FRESH_SETUP -eq 1 ]]; then
    echo "Fresh setup requested — cleaning feeds..."
    FORCE_CLEAN=1
elif [ "$NEW_HASH" != "$OLD_HASH" ]; then
    echo "feeds.conf changed — cleaning and force updating feeds..."
    FORCE_CLEAN=1
fi

if [ "$FORCE_CLEAN" -eq 1 ]; then
    ./scripts/feeds clean 2>/dev/null || true
    rm -rf feeds package/feeds
    ./scripts/feeds update -a -f 2>&1 | python3 "$BUILDER_ROOT/scripts/engine/filter_logs.py"
else
    ./scripts/feeds update -a 2>&1 | python3 "$BUILDER_ROOT/scripts/engine/filter_logs.py"
fi

echo "$NEW_HASH" > "$WORKTREE_DIR/.feeds.conf.hash"
