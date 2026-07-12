#!/bin/bash
set -eo pipefail

echo "==> Loading configuration..."

rm -f "$WORKTREE_DIR/.config"

if [ -f "$PROFILE_DIR/config.seed" ]; then
    cat "$PROFILE_DIR/config.seed" >> "$WORKTREE_DIR/.config"
fi

# Pass 1: Apply profile static packages and exclude packages
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

for pkg in sorted(packages - exclude):
    print(f"CONFIG_PACKAGE_{pkg}=y")
for pkg in sorted(exclude):
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

export OVERRIDE_VERMAGIC
OVERRIDE_VERMAGIC=$(python3 -c '
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(sys.argv[1], "rb") as f:
    print(tomllib.load(f).get("vermagic", ""))
' "$PROFILE_DIR/profile.toml" || true)

if [ -n "$OVERRIDE_VERMAGIC" ]; then
    echo "==> Vermagic override enabled: $OVERRIDE_VERMAGIC"
    echo "    Official kmod packages will be installable on this custom kernel."
fi

echo "==> Running Pass 1 defconfig..."
cd "$WORKTREE_DIR"
make defconfig

# Pass 2: Resolve dynamic dependencies against authoritative .config
echo "==> Resolving dynamic dependencies (Pass 2)..."
python3 -c '
import sys, os, subprocess
try:
    import tomllib
except ImportError:
    import tomli as tomllib

with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)

exclude = set(config.get("exclude_packages", []))
builder_root = sys.argv[2]
worktree_dir = sys.argv[3]
profile_dir = sys.argv[4]

packages = set()

def resolve_deps(s, category):
    base_path = os.path.join(builder_root, "shared", category, s)
    candidates = [f"{base_path}.deps.sh", f"{base_path}.deps.py", f"{base_path}.deps"]
    for path in candidates:
        if os.path.exists(path):
            if os.access(path, os.X_OK) or path.endswith(".deps.sh") or path.endswith(".deps.py"):
                cmd = [path, worktree_dir, profile_dir, builder_root]
                if not os.access(path, os.X_OK):
                    if path.endswith(".deps.sh"):
                        cmd = ["/bin/bash", path, worktree_dir, profile_dir, builder_root]
                    elif path.endswith(".deps.py"):
                        cmd = [sys.executable, path, worktree_dir, profile_dir, builder_root]
                try:
                    out = subprocess.check_output(cmd, text=True)
                    for line in out.splitlines():
                        line = line.split("#")[0].strip()
                        if line and line not in exclude:
                            packages.add(line)
                except subprocess.CalledProcessError as e:
                    print(f"WARNING: {path} exited with code {e.returncode}", file=sys.stderr)
                except Exception as e:
                    print(f"WARNING: failed to execute {path}: {e}", file=sys.stderr)
                return
            elif path.endswith(".deps"):
                with open(path, "r") as df:
                    for line in df:
                        line = line.split("#")[0].strip()
                        if line and line not in exclude:
                            packages.add(line)
                return

for s in config.get("shared_uci_defaults", []):
    resolve_deps(s, "uci-defaults")

for s in config.get("shared_preinit", []):
    resolve_deps(s, "preinit")

for pkg in sorted(packages - exclude):
    print(f"CONFIG_PACKAGE_{pkg}=y")
' "$PROFILE_DIR/profile.toml" "$BUILDER_ROOT" "$WORKTREE_DIR" "$PROFILE_DIR" >> "$WORKTREE_DIR/.config"

echo "==> Running Pass 2 defconfig..."
make defconfig
