#!/bin/bash
set -eo pipefail

IMAGE_NAME="$1"
if [ -z "$IMAGE_NAME" ] || [ -z "$BUILD_PASSWORD" ]; then
    echo "Usage: BUILD_PASSWORD=... unpack-ccache.sh <IMAGE_NAME>"
    exit 1
fi

echo "==> Restoring ccache from $IMAGE_NAME..."

mkdir -p .ccache

if docker pull "$IMAGE_NAME" 2>/dev/null; then
    echo "  -> Image pulled successfully."
    docker create --name ccache-seed "$IMAGE_NAME"
    mkdir -p /tmp/ccache-cache
    docker cp ccache-seed:/cache /tmp/ccache-cache/ || true
    docker rm ccache-seed

    if [ -d /tmp/ccache-cache/cache ]; then
        for enc_file in /tmp/ccache-cache/cache/*.tar.zst.enc; do
            if [ -f "$enc_file" ]; then
                echo "  -> Decrypting $(basename "$enc_file")..."
                openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BUILD_PASSWORD -in "$enc_file" | tar -x -I 'zstd -T0' -C .ccache
            fi
        done
    fi
    rm -rf /tmp/ccache-cache
    echo "  -> ccache uncompressed size:"
    du -sh .ccache 2>/dev/null | awk '{print "     " $0}' || true
    echo "==> ccache restored."
else
    echo "  -> Cache image not found. Will start fresh."
fi
