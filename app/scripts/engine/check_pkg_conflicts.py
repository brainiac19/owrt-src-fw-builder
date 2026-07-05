#!/usr/bin/env python3
"""
Pre-build package file conflict detector for OpenWrt/ImmortalWrt.

Scans feed Makefiles for file installation patterns and reports potential
file ownership conflicts between packages from different feeds — before
any compilation starts.

Strategy:
  - Grep all Makefiles under feeds/ for $(INSTALL_BIN/DATA/CONF) lines
  - Build a map of  installed_path → [(pkg, feed), ...]
  - Flag any path claimed by packages from MORE THAN ONE feed, where at
    least one of those feeds is a non-default (custom) feed
  - Filter to conflicts that involve a package that is directly selected
    in the profile OR comes from a custom feed (catches indirect deps too)

Usage:
    python3 check_pkg_conflicts.py <worktree_dir> <profile_toml>
"""

import re
import sys
from collections import defaultdict
from pathlib import Path

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ImportError:
        tomllib = None  # type: ignore[assignment]

# ---------------------------------------------------------------------------
# Regex patterns
# ---------------------------------------------------------------------------

# Matches the primary PKG_NAME assignment at the top of a Makefile.
PKG_NAME_RE = re.compile(r"^PKG_NAME\s*:?=\s*(.+)$", re.MULTILINE)

# Matches explicit single-file installs, e.g.:
#   $(INSTALL_BIN)  ./files/adguardhome.init  $(1)/etc/init.d/adguardhome
#   $(INSTALL_DATA) $(PKG_BUILD_DIR)/foo.conf $(1)/etc/config/foo
# Captures the destination path (group 1).
INSTALL_FILE_RE = re.compile(
    r"\$\(INSTALL_(?:BIN|DATA|CONF)\)\s+\S+\s+\$\(1\)(/\S+)"
)

# Default upstream OpenWrt feeds — conflicts within these are not our concern.
DEFAULT_FEEDS = frozenset({"packages", "luci", "routing", "telephony", "freifunk"})


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_selected_packages(profile_toml: Path) -> set:
    """Return the set of packages explicitly listed in profile.toml."""
    if tomllib is None:
        return set()
    with open(profile_toml, "rb") as f:
        config = tomllib.load(f)
    return set(config.get("packages", []))


def get_feed_name(makefile, feeds_dir):
    """Derive feed name from  feeds/<feedname>/...  path."""
    try:
        return makefile.relative_to(feeds_dir).parts[0]
    except (ValueError, IndexError):
        return "unknown"


def scan_feeds(worktree):
    """
    Walk every Makefile under  feeds/  and collect file-install lines.

    Returns:
        {"/etc/init.d/adguardhome": [{"pkg": ..., "feed": ..., "mf": ...}, ...]}
    """
    feeds_dir = worktree / "feeds"
    if not feeds_dir.exists():
        print(
            "  WARNING: feeds/ directory not found — run feeds update first.",
            file=sys.stderr,
        )
        return {}

    file_owners = defaultdict(list)

    for makefile in sorted(feeds_dir.rglob("Makefile")):
        try:
            content = makefile.read_text(errors="ignore")
        except OSError:
            continue

        m = PKG_NAME_RE.search(content)
        if not m:
            continue
        pkg_name = m.group(1).strip()
        feed_name = get_feed_name(makefile, feeds_dir)

        for hit in INSTALL_FILE_RE.finditer(content):
            dest_path = hit.group(1).rstrip()
            file_owners[dest_path].append(
                {
                    "pkg": pkg_name,
                    "feed": feed_name,
                    "mf": str(makefile.relative_to(worktree)),
                }
            )

    return file_owners


# ---------------------------------------------------------------------------
# Conflict detection
# ---------------------------------------------------------------------------

def check_conflicts(worktree, profile_toml):
    """
    Scan for cross-feed file conflicts and print a report.

    Returns True if any actionable conflicts were found.
    """
    selected = get_selected_packages(profile_toml) if profile_toml.exists() else set()

    print(f"  Scanning Makefiles under {worktree / 'feeds'} ...")
    file_owners = scan_feeds(worktree)
    print(f"  Indexed {len(file_owners)} unique destination paths across all feeds.\n")

    conflicts = []

    for dest_path, owners in sorted(file_owners.items()):
        if len(owners) < 2:
            continue  # no conflict possible

        feeds_involved = {o["feed"] for o in owners}
        if len(feeds_involved) < 2:
            continue  # all from the same feed — not our problem

        custom_feeds = feeds_involved - DEFAULT_FEEDS
        if not custom_feeds:
            continue  # conflict only among default feeds — skip

        # Surface if: any owner is from a custom feed OR is directly selected.
        is_relevant = bool(custom_feeds) or any(
            o["pkg"] in selected for o in owners
        )
        if is_relevant:
            conflicts.append((dest_path, owners))

    if not conflicts:
        print("  No cross-feed file ownership conflicts detected.")
        return False

    print(f"  ERROR: {len(conflicts)} potential file ownership conflict(s) found:\n")

    for dest_path, owners in conflicts:
        print(f"  CONFLICT  {dest_path}")
        for o in owners:
            tag = ""
            if o["pkg"] in selected:
                tag = "  <- directly selected"
            elif o["feed"] not in DEFAULT_FEEDS:
                tag = "  <- from custom feed"
            print(f"    [{o['feed']:12s}]  {o['pkg']}{tag}")
            print(f"               {o['mf']}")
        print()

    print("  How to fix:")
    print("  - Add the conflicting base package(s) to 'exclude_packages' in profile.toml")
    print("    so the custom-feed version is the sole provider.")
    print("  - Or pin the custom feed to a commit where the bundled file was removed.")
    print()

    return True


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <worktree_dir> <profile_toml>")
        sys.exit(2)

    worktree = Path(sys.argv[1])
    profile_toml = Path(sys.argv[2])

    if not worktree.is_dir():
        print(f"ERROR: worktree directory not found: {worktree}", file=sys.stderr)
        sys.exit(2)

    has_conflicts = check_conflicts(worktree, profile_toml)
    sys.exit(1 if has_conflicts else 0)


if __name__ == "__main__":
    main()
