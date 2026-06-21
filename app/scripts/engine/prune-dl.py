#!/usr/bin/env python3
import os
import re
import time
import shutil

dl_dir = "dl"
if not os.path.isdir(dl_dir):
    exit(0)

retention_days = int(os.environ.get('CACHE_RETENTION_DAYS', '30'))
now = time.time()
cutoff_time = now - (retention_days * 24 * 60 * 60)

print(f"==> Pruning all files older than {retention_days} days...")
# 1. Prune all files older than the retention period
for root, dirs, files in os.walk(dl_dir, topdown=False):
    for filename in files:
        filepath = os.path.join(root, filename)
        try:
            mtime = os.path.getmtime(filepath)
            if mtime < cutoff_time:
                print(f"Pruning expired file: {filepath}")
                os.remove(filepath)
        except OSError:
            pass
    # Clean up empty directories
    for dirname in dirs:
        dirpath = os.path.join(root, dirname)
        try:
            if not os.listdir(dirpath):
                print(f"Pruning empty directory: {dirpath}")
                os.rmdir(dirpath)
        except OSError:
            pass

# 2. Group top-level package tarballs and keep only the newest version
print("==> Deduplicating old package versions...")
pattern = re.compile(r'^([a-zA-Z0-9_+.]+?)-[0-9]')
packages = {}

for filename in os.listdir(dl_dir):
    filepath = os.path.join(dl_dir, filename)
    if not os.path.isfile(filepath):
        continue
    
    match = pattern.match(filename)
    if match:
        pkg_name = match.group(1)
    else:
        pkg_name = filename
        
    try:
        mtime = os.path.getmtime(filepath)
        if pkg_name not in packages:
            packages[pkg_name] = []
        packages[pkg_name].append((mtime, filepath))
    except OSError:
        pass

for pkg_name, files in packages.items():
    if len(files) > 1:
        # Sort by mtime descending (newest first)
        files.sort(key=lambda x: x[0], reverse=True)
        # Keep the first one, delete the rest
        for _, filepath in files[1:]:
            print(f"Pruning older cached download: {filepath}")
            try:
                os.remove(filepath)
            except OSError:
                pass

print("==> Pruning complete.")
