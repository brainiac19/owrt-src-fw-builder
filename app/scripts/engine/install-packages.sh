#!/bin/bash
set -eo pipefail

echo "==> Installing packages..."
cd "$WORKTREE_DIR"

# Use the native script to uninstall all existing feed symlinks robustly
./scripts/feeds uninstall -a

# feeds install -a respects feeds.conf order: the first feed in feeds.conf that
# provides a package wins the symlink in package/feeds/.  Since extra_feeds are
# prepended by apply-feeds.sh, the first extra_feed always has highest priority.
./scripts/feeds install -a

# ── Prune stale package binaries from removed/changed feeds ───────────────────
# Context: every compiled package lands in bin/packages/<arch>/<feedname>/*.apk.
# The build system's merge step (package/Makefile) symlinks ALL *.apk files from
# ALL feed subdirs into a combined PACKAGE_DIR_ALL and then builds a single apk
# index.  apk resolves packages by highest version — so a stale .apk left over
# from a feed that was removed or replaced in a previous run will still end up in
# the index and may win the version race, installing a version the user never
# intended.  This is what causes "trying to overwrite <file> owned by <pkg>":
# an outdated bundled package from a removed custom feed beats the current build.
#
# Fix: parse the ACTIVE feed names from feeds.conf, then delete the bin/packages
# output subdirectories for any feed name NOT in the active set.  This is safe:
# active feeds will (re)compile their packages; only truly stale dirs are removed.
python3 - "$WORKTREE_DIR" << 'PYEOF'
import sys
import shutil
import re
from pathlib import Path

worktree = Path(sys.argv[1])
feeds_conf = worktree / "feeds.conf"
if not feeds_conf.exists():
    feeds_conf = worktree / "feeds.conf.default"

# ── Step 1: Determine active feed names from feeds.conf ───────────────────────
active_feeds = set()
for line in feeds_conf.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split()
    if len(parts) >= 2:
        active_feeds.add(parts[1])

BUILTIN = {"base", "packages", "luci", "routing", "telephony", "freifunk",
           "targets", "kmods"}
active_feeds |= BUILTIN

# ── Step 2: Remove bin/packages dirs for completely inactive feeds ─────────────
bin_packages = worktree / "bin" / "packages"
if bin_packages.exists():
    for arch_dir in bin_packages.iterdir():
        if not arch_dir.is_dir():
            continue
        for feed_dir in arch_dir.iterdir():
            if not feed_dir.is_dir():
                continue
            if feed_dir.name not in active_feeds:
                print(f"  Pruning inactive feed dir: {feed_dir.relative_to(worktree)}")
                shutil.rmtree(feed_dir, ignore_errors=True)

# ── Step 3: Remove stale .apk files within active feeds ───────────────────────
# After `feeds install -a`, package/feeds/<feedname>/<pkgname>/ symlinks tell us
# exactly which source packages are currently selected for compilation per feed.
# Any .apk in bin/packages/<arch>/<feed>/ whose source package is no longer
# symlinked in package/feeds/<feed>/ is stale from a previous run and must be
# removed — otherwise it contaminates the merged apk index and causes version
# conflicts at image-assembly time.

pkg_feeds_dir = worktree / "package" / "feeds"

# Build map: feed_name -> set of active source package names
active_src_by_feed: dict = {}
if pkg_feeds_dir.exists():
    for feed_dir in pkg_feeds_dir.iterdir():
        if not feed_dir.is_dir():
            continue
        feed_name = feed_dir.name
        active_src_by_feed[feed_name] = set()
        for pkg_entry in feed_dir.iterdir():
            # Each entry is a symlink to the feed's package directory
            active_src_by_feed[feed_name].add(pkg_entry.name)

print(f"  Active source packages per feed:")
for feed, pkgs in sorted(active_src_by_feed.items()):
    print(f"    {feed}: {len(pkgs)} packages")

# APK filenames look like: <pkgname>[-<variant>]-<version>.apk
# We match by stripping version suffix: split on '-' and rebuild the pkg prefix.
# We use the set of active source package names for that feed as the allowlist.
# If a .apk's package name prefix doesn't match any active source package, prune it.

def apk_pkg_name(apk_path: Path) -> str:
    """Extract the package name from an .apk filename (strip version suffix)."""
    # apk filenames: <name>-<version>.apk where version starts with a digit
    stem = apk_path.stem  # strip .apk
    # version part starts after the last '-' that precedes a digit
    parts = stem.split("-")
    # Find the index where version begins (first part starting with a digit)
    for i, part in enumerate(parts):
        if part and part[0].isdigit():
            return "-".join(parts[:i])
    return stem  # fallback: no version found

if bin_packages.exists():
    for arch_dir in bin_packages.iterdir():
        if not arch_dir.is_dir():
            continue
        for feed_dir in arch_dir.iterdir():
            if not feed_dir.is_dir():
                continue
            feed_name = feed_dir.name
            if feed_name not in active_src_by_feed:
                continue  # handled by step 2 (inactive feed) or no symlinks known
            active_src = active_src_by_feed[feed_name]
            for apk_file in feed_dir.glob("*.apk"):
                pkg_name = apk_pkg_name(apk_file)
                if pkg_name not in active_src:
                    print(f"  Pruning stale package: {apk_file.relative_to(worktree)}"
                          f" (source '{pkg_name}' no longer in feed/{feed_name})")
                    apk_file.unlink(missing_ok=True)

print("  Stale package pruning complete.")
PYEOF
# ──────────────────────────────────────────────────────────────────────────────
