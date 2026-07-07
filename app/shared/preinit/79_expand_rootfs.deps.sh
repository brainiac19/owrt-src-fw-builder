#!/bin/bash
WORKTREE="$1"
CONFIG_FILE="$WORKTREE/.config"

# Base tools always required for partition table operations (losetup removed as unused)
echo "parted"

# Inspect target filesystem selections in generated .config
if grep -q "^CONFIG_TARGET_ROOTFS_EXT4FS=y" "$CONFIG_FILE" 2>/dev/null; then
    echo "e2fsprogs"
fi

if grep -q "^CONFIG_TARGET_ROOTFS_SQUASHFS=y" "$CONFIG_FILE" 2>/dev/null; then
    # Squashfs overlay targets generate f2fs or ext4 overlay volumes
    echo "e2fsprogs"
    echo "f2fs-tools"
fi

if grep -q "^CONFIG_TARGET_ROOTFS_F2FS=y" "$CONFIG_FILE" 2>/dev/null; then
    echo "f2fs-tools"
fi
