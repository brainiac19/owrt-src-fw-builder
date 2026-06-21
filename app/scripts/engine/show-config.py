import sys
import os
import glob
try:
    import tomllib
except ImportError:
    import tomli as tomllib

profile_dir = sys.argv[1]

with open(os.path.join(profile_dir, "profile.toml"), "rb") as f:
    config = tomllib.load(f)

print(f"Profile : {config.get('display_name', 'Unknown')}")
print(f"Source  : {config.get('repo', 'Unknown').split('/')[-1].replace('.git', '')} @ {config.get('branch', 'Unknown')}")
print("")

print("┌─ Target")
print(f"│   board    : {config.get('artifact_path', 'Unknown')}")
print(f"│   kernel   : {config.get('kernel_target', 'Unknown')}")

config_seed = []
if os.path.exists(os.path.join(profile_dir, "config.seed")):
    with open(os.path.join(profile_dir, "config.seed"), "r") as f:
        config_seed = [line.strip() for line in f if line.strip() and not line.startswith("#")]

target_opts = [c for c in config_seed if c.startswith("CONFIG_TARGET_")]
kernel_opts = [c for c in config_seed if c.startswith("CONFIG_KERNEL_")]
build_opts = [c for c in config_seed if c not in target_opts and c not in kernel_opts]

print(f"│   rootfs   : {next((c.split('=')[1] for c in target_opts if 'ROOTFS_PARTSIZE' in c), 'Unknown')} MB")
print(f"│   zstd     : {next((c.split('=')[1] for c in build_opts if 'ZSTD_OPTIMIZE' in c), 'N/A')}")
print("│")

print(f"├─ Kernel options ({len(kernel_opts)})")
if kernel_opts:
    print(f"│   {'  '.join(c.replace('CONFIG_KERNEL_', '') for c in kernel_opts[:5])} ...")
print("│")

packages = config.get("packages", [])
exclude = config.get("exclude_packages", [])
print(f"├─ Packages ({len(packages)})")
if packages:
    print(f"│   ├ {', '.join(packages[:5])} ...")
if exclude:
    print(f"│   └ [excluded] {', '.join(exclude)}")
else:
    print("│   └ [excluded] (none)")
print("│")

print("└─ Package build options")
pkg_options_dir = os.path.join(profile_dir, "pkg-options")
if os.path.isdir(pkg_options_dir):
    confs = glob.glob(os.path.join(pkg_options_dir, "*.conf"))
    for i, conf in enumerate(confs):
        pkg = os.path.basename(conf).replace(".conf", "")
        with open(conf, "r") as f:
            opts = [line.strip() for line in f if line.strip()]
        prefix = "└─" if i == len(confs) - 1 else "├─"
        print(f"    {prefix} {pkg}/ ({len(opts)} options)")
        if opts:
            print(f"    │   {'  '.join(c.split('=')[0].replace('CONFIG_'+pkg.upper().replace('-','_')+'_', '') + '=' + c.split('=')[1] for c in opts[:5])} ...")
