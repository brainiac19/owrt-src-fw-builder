#!/bin/bash
set -eo pipefail

IMAGE_NAME="$1"
if [ -z "$IMAGE_NAME" ] || [ -z "$BUILD_PASSWORD" ]; then
    echo "Usage: BUILD_PASSWORD=... unpack-source.sh <IMAGE_NAME>"
    exit 1
fi

echo "==> Restoring source cache from $IMAGE_NAME..."

mkdir -p source

if docker pull "$IMAGE_NAME" 2>/dev/null; then
    echo "  -> Image pulled successfully."
    docker create --name source-seed "$IMAGE_NAME"
    mkdir -p /tmp/source-cache
    docker cp source-seed:/cache /tmp/source-cache/ || true
    docker rm source-seed

    if [ -f "/tmp/source-cache/cache/source-main.tar.zst.enc" ]; then
        echo "  -> Decrypting source-main.tar.zst.enc..."
        openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BUILD_PASSWORD -in /tmp/source-cache/cache/source-main.tar.zst.enc | tar -x -I 'zstd -T0' -C source
    fi
    rm -rf /tmp/source-cache
    echo "==> Source cache restored."
else
    echo "  -> Cache image not found. Will start fresh."
fi
