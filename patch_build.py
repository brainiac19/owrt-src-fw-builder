import re

with open('.github/workflows/build.yml', 'r') as f:
    content = f.read()

# Block 1: Replace Restore Caches
old_restore = """      # ── Restore caches ────────────────────────────────────────────────────────
      # Split restore/save is the current recommended pattern replacing save-always.
      # Each cache gets an explicit save step at the end with `if: always()` so
      # the cache is persisted even when the build step itself fails.

      - name: Restore OpenWrt Source Cache
        id: cache-source
        uses: actions/cache/restore@v4
        with:
          path: source-main.tar.zst.enc
          key: openwrt-source-main-${{ github.run_id }}
          restore-keys: |
            openwrt-source-main-

      - name: Decrypt and Extract Source Cache
        if: steps.cache-source.outputs.cache-hit == 'true'
        run: |
          if [ -f source-main.tar.zst.enc ]; then
            openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BUILD_PASSWORD -in source-main.tar.zst.enc | tar -x -I 'zstd -T0'
            rm -f source-main.tar.zst.enc
          fi
        env:
          BUILD_PASSWORD: ${{ secrets.BUILD_PASSWORD }}

      - name: Restore Download Directory Cache
        id: cache-dl
        uses: actions/cache/restore@v4
        with:
          path: dl.tar.zst.enc
          # DL tarballs are profile-agnostic; fall back to any dl cache
          key: openwrt-dl-${{ matrix.profile }}-${{ hashFiles(format('profiles/{0}/profile.toml', matrix.profile)) }}
          restore-keys: |
            openwrt-dl-

      - name: Decrypt and Extract Download Cache
        if: steps.cache-dl.outputs.cache-hit == 'true'
        run: |
          if [ -f dl.tar.zst.enc ]; then
            openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BUILD_PASSWORD -in dl.tar.zst.enc | tar -x -I 'zstd -T0'
            rm -f dl.tar.zst.enc
          fi
        env:
          BUILD_PASSWORD: ${{ secrets.BUILD_PASSWORD }}

      - name: Restore ccache
        id: cache-ccache
        if: github.event.inputs.enable_ccache == 'true'
        uses: actions/cache/restore@v4
        with:
          path: ccache.tar.zst.enc
          key: openwrt-ccache-${{ matrix.profile }}-${{ github.run_id }}
          restore-keys: |
            openwrt-ccache-${{ matrix.profile }}-

      - name: Decrypt and Extract ccache
        if: steps.cache-ccache.outputs.cache-hit == 'true'
        run: |
          if [ -f ccache.tar.zst.enc ]; then
            openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BUILD_PASSWORD -in ccache.tar.zst.enc | tar -x -I 'zstd -T0'
            rm -f ccache.tar.zst.enc
          fi
        env:
          BUILD_PASSWORD: ${{ secrets.BUILD_PASSWORD }}

      # Docker image: use BuildKit inline layer cache instead of a tar blob.
      # This avoids storing a multi-GB tar in the 10 GB repo cache quota.
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build Docker Image (with layer cache)
        uses: docker/build-push-action@v6
        with:
          context: ./app
          load: true           # make the image available to the local daemon
          tags: firmware-builder:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max"""

new_restore = """      # ── Restore caches ────────────────────────────────────────────────────────

      - name: Define GHCR Cache Images
        id: cache-images
        run: |
          IMAGE_BASE="ghcr.io/$(echo '${{ github.repository }}' | tr '[:upper:]' '[:lower:]')"
          echo "SOURCE_IMAGE=${IMAGE_BASE}/source-cache-${{ matrix.profile }}:latest" >> $GITHUB_ENV
          echo "DL_IMAGE=${IMAGE_BASE}/dl-cache-${{ matrix.profile }}:latest" >> $GITHUB_ENV
          echo "CCACHE_IMAGE=${IMAGE_BASE}/ccache-${{ matrix.profile }}:latest" >> $GITHUB_ENV

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Restore OpenWrt Source Cache (GHCR)
        env:
          BUILD_PASSWORD: ${{ secrets.BUILD_PASSWORD }}
        run: ./app/scripts/engine/unpack-source.sh "$SOURCE_IMAGE"

      - name: Restore Download Directory Cache (GHCR)
        env:
          BUILD_PASSWORD: ${{ secrets.BUILD_PASSWORD }}
        run: ./app/scripts/engine/unpack-dl.sh "$DL_IMAGE"

      - name: Restore ccache (GHCR)
        if: github.event.inputs.enable_ccache == 'true'
        env:
          BUILD_PASSWORD: ${{ secrets.BUILD_PASSWORD }}
        run: ./app/scripts/engine/unpack-ccache.sh "$CCACHE_IMAGE"

      # Docker image: use BuildKit inline layer cache instead of a tar blob.
      # This avoids storing a multi-GB tar in the 10 GB repo cache quota.
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build Docker Image (with layer cache)
        uses: docker/build-push-action@v6
        with:
          context: ./app
          load: true           # make the image available to the local daemon
          tags: firmware-builder:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max"""

content = content.replace(old_restore, new_restore)

# Block 2: Setup Firmware Source
old_setup = """      - name: Compress and Encrypt Source Cache
        if: steps.cache-source.outputs.cache-hit != 'true'
        run: tar -c -I 'zstd -T0 -3' source/main/ | openssl enc -e -aes-256-cbc -pbkdf2 -pass env:BUILD_PASSWORD -out source-main.tar.zst.enc
        env:
          BUILD_PASSWORD: ${{ secrets.BUILD_PASSWORD }}

      - name: Save OpenWrt Source Cache
        if: steps.cache-source.outputs.cache-hit != 'true'
        uses: actions/cache/save@v4
        with:
          path: source-main.tar.zst.enc
          key: ${{ steps.cache-source.outputs.cache-primary-key }}

      - name: Delete Source Cache Archive
        if: always()
        run: rm -f source-main.tar.zst.enc || true"""

new_setup = """      - name: Hash Source for Change Detection
        run: |
          if [ -d "source/main/.git" ]; then
              git -C source/main rev-parse HEAD > .source-hash-before
          fi"""
content = content.replace(old_setup, new_setup)


# Block 3: Download cache save
old_dl_save = """      - name: Prune Download Cache
        if: always() && steps.cache-dl.outputs.cache-hit != 'true'
        env:
          CACHE_RETENTION_DAYS: ${{ github.event.inputs.cache_retention_days || '30' }}
        run: |
          if [ -d dl/ ]; then
            python3 app/scripts/engine/prune-dl.py
          fi

      - name: Compress and Encrypt Download Cache
        if: always() && steps.cache-dl.outputs.cache-hit != 'true'
        run: |
          if [ -d dl/ ]; then
            tar -c -I 'zstd -T0 -3' dl/ | openssl enc -e -aes-256-cbc -pbkdf2 -pass env:BUILD_PASSWORD -out dl.tar.zst.enc
          fi
        env:
          BUILD_PASSWORD: ${{ secrets.BUILD_PASSWORD }}

      - name: Save Download Directory Cache
        if: always() && steps.cache-dl.outputs.cache-hit != 'true'
        uses: actions/cache/save@v4
        with:
          path: dl.tar.zst.enc
          key: ${{ steps.cache-dl.outputs.cache-primary-key }}

      - name: Delete Download Cache Archive
        if: always()
        run: rm -f dl.tar.zst.enc || true"""

new_dl_save = """      - name: Prune Download Cache
        if: always()
        env:
          CACHE_RETENTION_DAYS: ${{ github.event.inputs.cache_retention_days || '30' }}
        run: |
          if [ -d dl/ ]; then
            python3 app/scripts/engine/prune-dl.py
          fi"""
content = content.replace(old_dl_save, new_dl_save)


# Block 4: Compile touch
old_compile = """      - name: Build Firmware - Compile
        run: |
          env UID=$(id -u) GID=$(id -g) \\"""

new_compile = """      - name: Mark Build Start for ccache
        run: touch .build-start

      - name: Build Firmware - Compile
        run: |
          env UID=$(id -u) GID=$(id -g) \\"""
content = content.replace(old_compile, new_compile)


# Block 5: End cache saves
old_end = """      - name: Compress and Encrypt ccache
        if: always() && github.event.inputs.enable_ccache == 'true'
        run: |
          if [ -d .ccache/ ]; then
            tar -c -I 'zstd -T0 -3' .ccache/ | openssl enc -e -aes-256-cbc -pbkdf2 -pass env:BUILD_PASSWORD -out ccache.tar.zst.enc
          fi
        env:
          BUILD_PASSWORD: ${{ secrets.BUILD_PASSWORD }}

      - name: Save ccache
        if: always() && github.event.inputs.enable_ccache == 'true'
        uses: actions/cache/save@v4
        with:
          path: ccache.tar.zst.enc
          key: openwrt-ccache-${{ matrix.profile }}-${{ github.run_id }}

      - name: Delete ccache Directory and Archive
        if: always()
        run: rm -rf .ccache/ ccache.tar.zst.enc || true



      - name: Delete Download Cache Directory
        if: always()
        run: rm -rf dl/ || true"""

new_end = """      - name: Pack and Push Source Cache (GHCR)
        if: always()
        env:
          BUILD_PASSWORD: ${{ secrets.BUILD_PASSWORD }}
        run: ./app/scripts/engine/pack-source.sh "$SOURCE_IMAGE"

      - name: Pack and Push Download Cache (GHCR)
        if: always()
        env:
          BUILD_PASSWORD: ${{ secrets.BUILD_PASSWORD }}
        run: ./app/scripts/engine/pack-dl.sh "$DL_IMAGE"

      - name: Pack and Push ccache (GHCR)
        if: always() && github.event.inputs.enable_ccache == 'true'
        env:
          BUILD_PASSWORD: ${{ secrets.BUILD_PASSWORD }}
        run: ./app/scripts/engine/pack-ccache.sh "$CCACHE_IMAGE"

      - name: Delete Raw Cache Directories
        if: always()
        run: rm -rf dl/ .ccache/ source/main/ || true"""
content = content.replace(old_end, new_end)


# Block 6: Pruning GHCR images
old_prune = """      - name: Prune Old GHCR Toolchains
        if: always()
        uses: actions/delete-package-versions@v5
        with:
          package-name: toolchain-${{ matrix.profile }}
          package-type: 'container'
          min-versions-to-keep: 1
          delete-only-untagged-versions: 'false'"""

new_prune = """      - name: Prune Old GHCR Toolchains
        if: always()
        uses: actions/delete-package-versions@v5
        with:
          package-name: toolchain-${{ matrix.profile }}
          package-type: 'container'
          min-versions-to-keep: 1
          delete-only-untagged-versions: 'false'

      - name: Prune Old GHCR Source Cache
        if: always()
        uses: actions/delete-package-versions@v5
        with:
          package-name: source-cache-${{ matrix.profile }}
          package-type: 'container'
          min-versions-to-keep: 1
          delete-only-untagged-versions: 'false'

      - name: Prune Old GHCR Download Cache
        if: always()
        uses: actions/delete-package-versions@v5
        with:
          package-name: dl-cache-${{ matrix.profile }}
          package-type: 'container'
          min-versions-to-keep: 1
          delete-only-untagged-versions: 'false'

      - name: Prune Old GHCR ccache
        if: always() && github.event.inputs.enable_ccache == 'true'
        uses: actions/delete-package-versions@v5
        with:
          package-name: ccache-${{ matrix.profile }}
          package-type: 'container'
          min-versions-to-keep: 1
          delete-only-untagged-versions: 'false'"""
content = content.replace(old_prune, new_prune)

with open('.github/workflows/build.yml', 'w') as f:
    f.write(content)
