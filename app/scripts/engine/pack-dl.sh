#!/bin/bash
set -eo pipefail

IMAGE_NAME="$1"
if [ -z "$IMAGE_NAME" ] || [ -z "$BUILD_PASSWORD" ]; then
    echo "Usage: BUILD_PASSWORD=... pack-dl.sh <IMAGE_NAME>"
    exit 1
fi

echo "==> Packing dl cache into $IMAGE_NAME (Iterative Layering)..."

if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    IMAGE_EXISTS=1
else
    IMAGE_EXISTS=0
fi

if [ ! -d "dl" ]; then
    echo "dl directory not found, skipping."
    exit 0
fi

echo "  -> dl cache uncompressed size before packing:"
du -sh dl 2>/dev/null | awk '{print "     " $0}' || true

CHUNKS=(a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9 other)

mkdir -p /tmp/dl-chunks
for f in dl/*; do
    if [ ! -f "$f" ]; then continue; fi
    base=$(basename "$f")
    first_char=$(echo "${base:0:1}" | tr '[:upper:]' '[:lower:]')
    
    chunk="other"
    if [[ "$first_char" =~ [a-z0-9] ]]; then
        chunk="$first_char"
    fi
    
    mkdir -p "/tmp/dl-chunks/$chunk"
    ln "$f" "/tmp/dl-chunks/$chunk/" 2>/dev/null || cp "$f" "/tmp/dl-chunks/$chunk/"
done

docker pull busybox:1 2>/dev/null || true
docker tag busybox:1 "temp-dl:0"

i=1
mkdir -p /tmp/dl-ctx

for chunk in "${CHUNKS[@]}"; do
    chunk_dir="/tmp/dl-chunks/$chunk"
    
    hash_before=""
    if [ -f ".dl-hashes-$chunk-before" ]; then
        hash_before=$(cat ".dl-hashes-$chunk-before")
    fi
    
    hash_after=""
    if [ -d "$chunk_dir" ] && [ "$(ls -A "$chunk_dir" 2>/dev/null)" ]; then
        hash_after=$(cd "$chunk_dir" && find . -type f -exec stat -c "%n %s" {} + | sort | sha256sum | awk '{print $1}')
    fi
    
    CHANGED=0
    if [ "$IMAGE_EXISTS" -eq 0 ]; then
        CHANGED=1
    elif [ "$hash_before" != "$hash_after" ]; then
        CHANGED=1
    fi

    cat > /tmp/dl-ctx/Dockerfile <<EOF
FROM temp-dl:$((i-1))
EOF

    if [ "$CHANGED" -eq 1 ] && [ -n "$hash_after" ]; then
        echo "  -> Chunk $chunk changed. Compressing..."
        tar -c -I 'zstd -T0 -3' -C /tmp/dl-chunks "$chunk" | openssl enc -e -aes-256-cbc -pbkdf2 -pass env:BUILD_PASSWORD -out "/tmp/dl-ctx/$chunk.tar.zst.enc"
        echo "COPY $chunk.tar.zst.enc /cache/" >> /tmp/dl-ctx/Dockerfile
        
        docker build -t "temp-dl:$i" /tmp/dl-ctx
        rm -f "/tmp/dl-ctx/$chunk.tar.zst.enc"
        
    elif [ "$CHANGED" -eq 0 ] && [ -n "$hash_before" ]; then
        echo "  -> Chunk $chunk unchanged. Reusing layer..."
        echo "COPY --from=$IMAGE_NAME /cache/$chunk.tar.zst.enc /cache/" >> /tmp/dl-ctx/Dockerfile
        docker build -t "temp-dl:$i" /tmp/dl-ctx
        
    elif [ "$CHANGED" -eq 1 ] && [ -z "$hash_after" ]; then
        echo "  -> Chunk $chunk is now empty. Removing from cache."
        docker build -t "temp-dl:$i" /tmp/dl-ctx
    else
        echo "  -> Chunk $chunk unchanged (empty). Reusing layer..."
        docker build -t "temp-dl:$i" /tmp/dl-ctx
    fi

    rm -rf "$chunk_dir"
    i=$((i+1))
done

FINAL_TAG="temp-dl:$((i-1))"
echo "==> Tagging and pushing final image..."
docker tag "$FINAL_TAG" "$IMAGE_NAME"
docker push "$IMAGE_NAME"

for j in $(seq 0 $((i-1))); do
    docker rmi "temp-dl:$j" 2>/dev/null || true
done
rm -rf /tmp/dl-ctx /tmp/dl-chunks
echo "==> dl cache packed successfully."
