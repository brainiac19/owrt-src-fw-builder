#!/bin/bash
set -eo pipefail

IMAGE_NAME="$1"
if [ -z "$IMAGE_NAME" ] || [ -z "$BUILD_PASSWORD" ]; then
    echo "Usage: BUILD_PASSWORD=... pack-source.sh <IMAGE_NAME>"
    exit 1
fi

echo "==> Packing source cache into $IMAGE_NAME (Iterative Layering)..."

if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    IMAGE_EXISTS=1
else
    IMAGE_EXISTS=0
fi

if [ ! -d "source/main" ]; then
    echo "source/main directory not found, skipping."
    exit 0
fi

HASH_BEFORE=""
if [ -f ".source-hash-before" ]; then
    HASH_BEFORE=$(cat .source-hash-before)
fi

HASH_AFTER=$(git -C source/main rev-parse HEAD 2>/dev/null || echo "nohash")

CHANGED=0
if [ "$IMAGE_EXISTS" -eq 0 ]; then
    CHANGED=1
elif [ "$HASH_BEFORE" != "$HASH_AFTER" ]; then
    CHANGED=1
fi

docker pull busybox:1 2>/dev/null || true
docker tag busybox:1 "temp-source:0"

mkdir -p /tmp/source-ctx
cat > /tmp/source-ctx/Dockerfile << 'EOF'
FROM temp-source:0
EOF

if [ "$CHANGED" -eq 1 ]; then
    echo "  -> Source changed (or new image). Compressing..."
    echo "  -> Source cache uncompressed size before packing:"
    du -sh source/main 2>/dev/null | awk '{print "     " $0}' || true
    tar -c -I 'zstd -T0 -3' -C source main | openssl enc -e -aes-256-cbc -pbkdf2 -pass env:BUILD_PASSWORD -out /tmp/source-ctx/source-main.tar.zst.enc
    
    # Aggressive pruning immediately after compression
    rm -rf source/main

    echo "COPY source-main.tar.zst.enc /cache/" >> /tmp/source-ctx/Dockerfile
    
    docker build -t "temp-source:1" /tmp/source-ctx
    rm -f /tmp/source-ctx/source-main.tar.zst.enc
else
    echo "  -> Source unchanged. Reusing layer..."
    # Aggressive pruning immediately
    rm -rf source/main

    echo "COPY --from=$IMAGE_NAME /cache/source-main.tar.zst.enc /cache/" >> /tmp/source-ctx/Dockerfile
    docker build -t "temp-source:1" /tmp/source-ctx
fi

echo "==> Tagging and pushing final image..."
docker tag "temp-source:1" "$IMAGE_NAME"
docker push "$IMAGE_NAME"

docker rmi "temp-source:0" "temp-source:1" 2>/dev/null || true
rm -rf /tmp/source-ctx
echo "==> Source cache packed successfully."
