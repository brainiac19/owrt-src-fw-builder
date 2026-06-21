#!/bin/bash
set -eo pipefail

IMAGE_NAME="$1"
if [ -z "$IMAGE_NAME" ] || [ -z "$BUILD_PASSWORD" ]; then
    echo "Usage: BUILD_PASSWORD=... pack-ccache.sh <IMAGE_NAME>"
    exit 1
fi

echo "==> Packing ccache into $IMAGE_NAME (Iterative Layering)..."

if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    IMAGE_EXISTS=1
else
    IMAGE_EXISTS=0
fi

if [ ! -d ".ccache" ]; then
    echo ".ccache directory not found, skipping."
    exit 0
fi

# Initialize base image
docker pull busybox:1 2>/dev/null || true
docker tag busybox:1 "temp-ccache:0"

i=1
mkdir -p /tmp/ccache-ctx

for b in $(ls -A .ccache 2>/dev/null); do
    if [ ! -e ".ccache/$b" ]; then
        continue
    fi

    CHANGED=0
    if [ "$IMAGE_EXISTS" -eq 0 ]; then
        CHANGED=1
    elif [ -f ".build-start" ]; then
        if [[ "$b" == *stats* ]]; then
            CHANGED=1
        else
            NEWER_FILES=$(find ".ccache/$b" -type f -not -name "*stats*" -newer .build-start 2>/dev/null | head -n 1)
            if [ -n "$NEWER_FILES" ]; then
                CHANGED=1
            fi
        fi
    else
        CHANGED=1
    fi

    cat > /tmp/ccache-ctx/Dockerfile <<EOF
FROM temp-ccache:$((i-1))
EOF

    if [ "$CHANGED" -eq 1 ]; then
        echo "  -> Bucket $b changed. Compressing..."
        tar -c -I 'zstd -T0 -3' -C .ccache "$b" | openssl enc -e -aes-256-cbc -pbkdf2 -pass env:BUILD_PASSWORD -out "/tmp/ccache-ctx/$b.tar.zst.enc"
        echo "COPY $b.tar.zst.enc /cache/" >> /tmp/ccache-ctx/Dockerfile
        
        # Build layer
        docker build -t "temp-ccache:$i" /tmp/ccache-ctx
        
        # DELETE archive immediately
        rm -f "/tmp/ccache-ctx/$b.tar.zst.enc"
    else
        echo "  -> Bucket $b unchanged. Reusing layer..."
        echo "COPY --from=$IMAGE_NAME /cache/$b.tar.zst.enc /cache/" >> /tmp/ccache-ctx/Dockerfile
        docker build -t "temp-ccache:$i" /tmp/ccache-ctx
    fi

    # DELETE raw uncompressed bucket immediately
    rm -rf ".ccache/$b"
    
    i=$((i+1))
done

# Finalize image
FINAL_TAG="temp-ccache:$((i-1))"
echo "==> Tagging and pushing final image..."
docker tag "$FINAL_TAG" "$IMAGE_NAME"
docker push "$IMAGE_NAME"

# Cleanup intermediate tags
for j in $(seq 0 $((i-1))); do
    docker rmi "temp-ccache:$j" 2>/dev/null || true
done
rm -rf /tmp/ccache-ctx
echo "==> ccache packed successfully."
