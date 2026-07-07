#!/bin/bash
WORKTREE="$1"
CONFIG_FILE="$WORKTREE/.config"

# Base tools always required for partition table operations
echo "parted"
# partprobe/partx is used to make the kernel re-read the partition table
# after parted modifies it; without one of these, resize2fs/resize.f2fs
# can run against a stale partition size. util-linux provides partx;
# partprobe usually ships alongside parted itself, but declare util-linux
# explicitly since the runtime script falls back to `partx -u` when
# partprobe isn't present.
echo "util-linux"

# Inspect target filesystem selections in generated .config
if grep -q "^CONFIG_TARGET_ROOTFS_EXT4FS=y" "$CONFIG_FILE" 2>/dev/null; then
    echo "e2fsprogs"
fi
if grep -q "^CONFIG_TARGET_ROOTFS_SQUASHFS=y" "$CONFIG_FILE" 2>/dev/null; then
    # Squashfs overlay targets generate f2fs or ext4 overlay volumes.
    # Both are pulled in conservatively since we can't always tell which
    # one a given target picked from this config alone. If your target
    # has a distinct Kconfig symbol for overlay fs type, prefer branching
    # on that instead of always including both.
    echo "e2fsprogs"
    echo "f2fs-tools"
fi
if grep -q "^CONFIG_TARGET_ROOTFS_F2FS=y" "$CONFIG_FILE" 2>/dev/null; then
    echo "f2fs-tools"
fi