#!/bin/bash
set -eo pipefail

IMAGE_NAME="$1"
if [ -z "$IMAGE_NAME" ] || [ -z "$BUILD_PASSWORD" ]; then
    echo "Usage: BUILD_PASSWORD=... unpack-dl.sh <IMAGE_NAME>"
    exit 1
fi

echo "==> Restoring dl cache from $IMAGE_NAME..."

mkdir -p dl
if docker pull "$IMAGE_NAME" 2>/dev/null; then
    echo "  -> Image pulled successfully."
    docker create --name dl-seed "$IMAGE_NAME"
    mkdir -p /tmp/dl-cache
    docker cp dl-seed:/cache /tmp/dl-cache/ || true
    docker rm dl-seed

    if [ -d /tmp/dl-cache/cache ]; then
        for enc_file in /tmp/dl-cache/cache/*.tar.zst.enc; do
            if [ -f "$enc_file" ]; then
                echo "  -> Decrypting $(basename "$enc_file")..."
                mkdir -p /tmp/dl-extract
                openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BUILD_PASSWORD -in "$enc_file" | tar -x -I 'zstd -T0' -C /tmp/dl-extract
                
                chunk_name=$(basename "$enc_file" .tar.zst.enc)
                if [ -d "/tmp/dl-extract/$chunk_name" ]; then
                    mv /tmp/dl-extract/"$chunk_name"/* dl/ 2>/dev/null || true
                fi
                rm -rf /tmp/dl-extract
            fi
        done
    fi
    rm -rf /tmp/dl-cache
    echo "==> dl cache restored."
else
    echo "  -> Cache image not found. Will start fresh."
fi

echo "==> Generating pre-build hashes..."
CHUNKS=(a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9 other)

for chunk in "${CHUNKS[@]}"; do
    rm -f ".dl-hashes-$chunk-before"
done

mkdir -p /tmp/dl-prehash
for f in dl/*; do
    if [ ! -f "$f" ]; then continue; fi
    base=$(basename "$f")
    first_char=$(echo "${base:0:1}" | tr '[:upper:]' '[:lower:]')
    
    chunk="other"
    if [[ "$first_char" =~ [a-z0-9] ]]; then
        chunk="$first_char"
    fi
    
    size=$(stat -c "%s" "$f")
    echo "./$base $size" >> "/tmp/dl-prehash/$chunk.txt"
done

for chunk in "${CHUNKS[@]}"; do
    if [ -f "/tmp/dl-prehash/$chunk.txt" ]; then
        sort "/tmp/dl-prehash/$chunk.txt" | sha256sum | awk '{print $1}' > ".dl-hashes-$chunk-before"
    fi
done
rm -rf /tmp/dl-prehash
