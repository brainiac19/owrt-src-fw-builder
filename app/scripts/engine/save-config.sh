#!/bin/bash
set -eo pipefail

echo "==> Saving configuration..."

if [ ! -d "$WORKTREE_DIR" ]; then
    echo "Error: Worktree not found."
    exit 1
fi

cd "$WORKTREE_DIR"
make savedefconfig

echo "Routing options back to profile..."
python3 -c '
import sys
import os
import glob
import re

try:
    import tomllib
except ImportError:
    import tomli as tomllib

profile_dir = sys.argv[1]
worktree_dir = sys.argv[2]
defconfig_path = os.path.join(worktree_dir, "defconfig")

pkg_prefixes = {"DOCKER": "docker", "LIBCURL": "libcurl"}
for m in glob.glob(os.path.join(worktree_dir, "feeds/*/*/Makefile")):
    parts = m.split("/")
    if len(parts) >= 3:
        orig_name = parts[-2]
        prefix = orig_name.upper().replace("-", "_").replace(".", "_").replace("+", "X")
        pkg_prefixes[prefix] = orig_name

with open(os.path.join(profile_dir, "profile.toml"), "rb") as f:
    config = tomllib.load(f)

packages = set(config.get("packages", []))
exclude_packages = set(config.get("exclude_packages", []))

pkg_options = {}
config_seed = []

known_prefixes = {"ZSTD", "PCRE2", "PARTED", "HTOP"}

with open(defconfig_path, "r") as f:
    lines = f.readlines()

for line in lines:
    line = line.strip()
    if not line:
        continue
    
    if line.startswith("CONFIG_PACKAGE_"):
        pkg = line.split("=")[0].replace("CONFIG_PACKAGE_", "")
        packages.add(pkg)
    elif line.startswith("# CONFIG_PACKAGE_"):
        pkg = line.split(" ")[1].replace("CONFIG_PACKAGE_", "")
        exclude_packages.add(pkg)
        if pkg in packages:
            packages.remove(pkg)
    elif line.startswith("CONFIG_"):
        key = line.split("=")[0]
        prefix = key.split("_")[1] if len(key.split("_")) > 1 else ""
        
        is_pkg_option = False
        pkg_name = ""
        
        if prefix not in {"TARGET", "KERNEL"} and prefix not in known_prefixes:
            key_stripped = key[7:]
            if not key_stripped.startswith("PACKAGE_"):
                parts = key_stripped.split("_")
                matched_pkg_orig = ""
                for i in range(len(parts), 0, -1):
                    candidate = "_".join(parts[:i])
                    if candidate in pkg_prefixes:
                        matched_pkg_orig = pkg_prefixes[candidate]
                        break
                if matched_pkg_orig:
                    is_pkg_option = True
                    pkg_name = matched_pkg_orig

        if is_pkg_option:
            if pkg_name not in pkg_options:
                pkg_options[pkg_name] = []
            pkg_options[pkg_name].append(line)
        else:
            config_seed.append(line)

with open(os.path.join(profile_dir, "config.seed"), "w") as f:
    f.write("\n".join(sorted(config_seed)) + "\n")

os.makedirs(os.path.join(profile_dir, "pkg-options"), exist_ok=True)
for conf in glob.glob(os.path.join(profile_dir, "pkg-options/*.conf")):
    os.remove(conf)

for pkg, opts in pkg_options.items():
    with open(os.path.join(profile_dir, f"pkg-options/{pkg}.conf"), "w") as f:
        f.write("\n".join(sorted(opts)) + "\n")

with open(os.path.join(profile_dir, "profile.toml"), "r") as f:
    content = f.read()

pkg_str = "packages = [\n  " + ", ".join(f"\"{p}\"" for p in sorted(packages)) + "\n]"
content = re.sub(r"packages\s*=\s*\[.*?\]", pkg_str, content, flags=re.DOTALL)

exc_str = "exclude_packages = [\n" + (", ".join(f"\"{p}\"" for p in sorted(exclude_packages)) if exclude_packages else "") + "\n]"
content = re.sub(r"exclude_packages\s*=\s*\[.*?\]", exc_str, content, flags=re.DOTALL)

with open(os.path.join(profile_dir, "profile.toml"), "w") as f:
    f.write(content)
' "$PROFILE_DIR" "$WORKTREE_DIR"

echo "Config saved to profile $PROFILE."
