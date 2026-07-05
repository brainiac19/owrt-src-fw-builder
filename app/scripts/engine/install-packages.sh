#!/bin/bash
set -eo pipefail

echo "==> Installing packages..."
cd "$WORKTREE_DIR"

# Use the native script to uninstall all existing feed symlinks robustly
./scripts/feeds uninstall -a

./scripts/feeds install -a

# ── Extra-feed priority enforcement ───────────────────────────────────────────
# `feeds install -a` does not honour feeds.conf ordering when multiple feeds
# provide the same package — whichever feed is processed last wins the symlink.
# To guarantee that the FIRST extra_feed in profile.toml always has the highest
# priority (i.e. its package versions override those from later extra_feeds and
# from the default feeds), we re-run `feeds install -p <feed>` for each extra
# feed in REVERSE order, ending with the highest-priority feed.  Because each
# call overwrites any existing symlink, the last call (highest priority) wins.
python3 -c '
import sys, subprocess
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(sys.argv[1], "rb") as f:
    cfg = tomllib.load(f)
feeds = cfg.get("extra_feeds", [])
# Parse feed names from "src-git <name> <url>" lines
feed_names = []
for line in feeds:
    parts = line.split()
    if len(parts) >= 2:
        feed_names.append(parts[1])
# Apply in reverse: lowest priority first, highest priority last
for name in reversed(feed_names):
    print(f"  Re-applying extra feed (priority enforcement): {name}", flush=True)
    subprocess.run(["./scripts/feeds", "install", "-p", name, "-a"],
                   check=False, capture_output=False)
' "$PROFILE_DIR/profile.toml"
# ──────────────────────────────────────────────────────────────────────────────

echo "==> Checking for pre-build package file conflicts..."
python3 "$BUILDER_ROOT/scripts/engine/check_pkg_conflicts.py" \
    "$WORKTREE_DIR" \
    "$PROFILE_DIR/profile.toml"
