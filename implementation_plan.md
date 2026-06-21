# Implementation Plan: GHCR Toolchain Caching (Option 3 — Docker Data Image)

## Goal

Cache the OpenWrt toolchain (`staging_dir/toolchain-*`, `staging_dir/host/`, `build_dir/toolchain-*`) as a proper OCI data image on GHCR. On a cache hit the toolchain is extracted from the image directly into the volume-mounted source tree before the build starts, so `make` skips the 40–60 min toolchain compilation entirely.

## Architecture

```
Run N (cache miss)
───────────────────────────────────────────────────────
Setup → Hash → GHCR pull (miss) → Build (full, ~60 min)
                                        │
                                        ▼
                                 Pack toolchain → docker push → GHCR
                                 (before disk-reclaim step)

Run N+1 (cache hit)
───────────────────────────────────────────────────────
Setup → Hash → GHCR pull (hit) → docker cp → touch stamps → Build (~10 min)
```

The key insight: the toolchain is stored at a **neutral path** (`/toolchain/staging_dir`, `/toolchain/build_dir`) inside the image. On restore, `docker cp` extracts these directories onto the **host**, where they are then picked up by the existing `./source:/builder/source` volume mount. No changes to the Docker Compose or volume structure are required.

---

## Files Changed

| File | Change |
|---|---|
| `.github/workflows/build.yml` | Add permissions, login, hash, restore, and save steps |
| `app/scripts/engine/07-compile.sh` | Add stamp-touching block |

---

## Proposed Changes

### 1. `.github/workflows/build.yml`

#### 1a. Add `packages: write` permission

The job block needs an explicit permission grant so `GITHUB_TOKEN` can push to GHCR.

```yaml
jobs:
  build:
    name: Build ${{ matrix.profile }}
    runs-on: ubuntu-latest
    needs: setup
    permissions:
      contents: read
      packages: write          # ← required for ghcr.io push
```

> [!NOTE]
> For public repositories, pushed GHCR packages are also public by default. For private repos they inherit the repo's visibility. No extra configuration is needed either way — GHCR is tied to the repository owner automatically via `GITHUB_TOKEN`.

---

#### 1b. Add GHCR Login step

Insert this immediately **after** the `Set up Docker Buildx` step and **before** `Build Docker Image`. Logging in early means the GHCR credential is available for both the pull (restore) and push (save) later.

```yaml
      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
```

---

#### 1c. Add Toolchain Hash Calculation step

Insert this **after** `Save OpenWrt Source Cache` (so `source/main/` is populated by the setup step). The hash must capture every input that influences the cross-compiler output:

```yaml
      - name: Calculate Toolchain Cache Hash
        id: toolchain-hash
        run: |
          PROFILE="${{ matrix.profile }}"
          # Actual commit SHA — the shallow fetch may have advanced the branch
          SOURCE_SHA=$(git -C source/main rev-parse HEAD)

          HASH=$(printf '%s\n' \
            "$(cat profiles/${PROFILE}/profile.toml)" \
            "${SOURCE_SHA}" \
            "$(cat source/main/include/toolchain.mk)" \
            "$(cat source/main/feeds.conf.default)" \
            | sha256sum | head -c 16)

          IMAGE_BASE="ghcr.io/$(echo '${{ github.repository }}' | tr '[:upper:]' '[:lower:]')"
          IMAGE="${IMAGE_BASE}/toolchain-${PROFILE}:${HASH}"

          echo "hash=${HASH}"       >> $GITHUB_OUTPUT
          echo "image=${IMAGE}"     >> $GITHUB_OUTPUT
          echo "TOOLCHAIN_IMAGE=${IMAGE}" >> $GITHUB_ENV
```

**Why these four inputs?**

| Input | Reason |
|---|---|
| `profile.toml` | Target arch, repo, branch — all affect GCC configuration |
| `SOURCE_SHA` | A shallow fetch can silently advance the branch; commit SHA is the ground truth |
| `include/toolchain.mk` | Defines GCC version, musl version, binutils version |
| `feeds.conf.default` | Feed URLs/revisions affect which host tools are built |

> [!IMPORTANT]
> `SOURCE_SHA` is obtained **after** `git clone --depth=1` has run, not from the API. This guarantees the hash reflects the exact tree that will be compiled against. If the upstream branch advances between a cache save and the next run, the SHA changes, the hash misses, and the build naturally rebuilds with the new sources — no stale-cache corruption.

---

#### 1d. Add Toolchain Restore step

Insert this **after** the hash step, **before** `Build Firmware`.

```yaml
      - name: Restore Toolchain from GHCR
        id: toolchain-restore
        run: |
          PROFILE="${{ matrix.profile }}"
          WORKTREE="source/worktrees/${PROFILE}"

          echo "Attempting to pull toolchain image: ${TOOLCHAIN_IMAGE}"
          if docker pull "${TOOLCHAIN_IMAGE}" 2>/dev/null; then
            echo "Cache HIT — extracting toolchain..."
            mkdir -p "${WORKTREE}"

            # Create a temporary container from the data image (no need to run it)
            docker create --name tc-seed "${TOOLCHAIN_IMAGE}"

            # Extract the two directory trees from the neutral /toolchain/ path
            # into the volume-mounted host location
            docker cp tc-seed:/toolchain/staging_dir "${WORKTREE}/staging_dir"
            docker cp tc-seed:/toolchain/build_dir   "${WORKTREE}/build_dir"

            docker rm tc-seed

            echo "TOOLCHAIN_RESTORED=true" >> $GITHUB_ENV
            echo "restored=true"           >> $GITHUB_OUTPUT
            echo "Toolchain extracted successfully."
          else
            echo "Cache MISS — toolchain will be built from scratch."
            echo "TOOLCHAIN_RESTORED=false" >> $GITHUB_ENV
            echo "restored=false"           >> $GITHUB_OUTPUT
          fi
```

**Why `docker cp` to host instead of running the image directly?**

The build container is launched by `docker compose run` with a bind mount `./source:/builder/source`. Whatever lives in `./source/` on the host **is** what the container sees at `/builder/source/`. By writing the toolchain to `./source/worktrees/$PROFILE/` on the host before the compose run, the container picks it up automatically — no changes to `docker-compose.yml`, no new volumes, no `--volumes-from`.

**Why the neutral `/toolchain/` path in the image?**

The toolchain binaries compiled by OpenWrt contain baked-in absolute paths to the **container-internal** location (e.g., `/builder/source/worktrees/nanopi-r4s/staging_dir/toolchain-aarch64_.../`). If we store them at that same path inside the OCI image, `docker cp` extracts them to a *host* path that differs (e.g., `./source/worktrees/...`). Storing them at a neutral `/toolchain/` and extracting to the host path that the volume then maps back to `/builder/source/worktrees/...` preserves the baked paths correctly because the path inside the running container is always `/builder/source/worktrees/$PROFILE/staging_dir/...` regardless of what the host path looks like.

---

#### 1e. Modify the Build Firmware step

Pass the `TOOLCHAIN_RESTORED` environment variable into the container so `07-compile.sh` can act on it:

```yaml
      - name: Build Firmware
        run: |
          mkdir -p profiles source dl .ccache artifacts
          env UID=$(id -u) GID=$(id -g) \
            TOOLCHAIN_RESTORED="${TOOLCHAIN_RESTORED:-false}" \
          docker compose run --rm \
            -e TOOLCHAIN_RESTORED \
            -e CCACHE_MAX_SIZE=${{ github.event.inputs.ccache_size || '20G' }} \
            builder bash -c "
              builder load-config --profile ${{ matrix.profile }} &&
              builder compile --profile ${{ matrix.profile }} \
                ${{ github.event.inputs.fallback_single_core == 'true' && '--fallback' || '' }} \
                ${{ github.event.inputs.enable_ccache == 'true' && '--ccache' || '' }} &&
              builder export-artifacts --profile ${{ matrix.profile }}"
```

---

#### 1f. Add Toolchain Save step

Insert this **immediately before** the existing `Reclaim Disk Space for Cache Save` step. It must run before that step because disk reclaim nukes the Docker daemon (`sudo rm -rf /var/lib/docker`).

```yaml
      - name: Save Toolchain to GHCR
        if: success() && env.TOOLCHAIN_RESTORED != 'true'
        run: |
          PROFILE="${{ matrix.profile }}"
          WORKTREE="source/worktrees/${PROFILE}"

          echo "==> Packing toolchain directories..."
          # Archive only the toolchain-specific subdirectories, not all of staging_dir.
          # This avoids including package sysroots that can be rebuilt quickly.
          #
          # Directory layout inside the tar (rooted at .):
          #   staging_dir/toolchain-*/   ← cross-compiler (gcc, binutils, sysroot)
          #   staging_dir/host/          ← host utilities (cmake, ninja, etc.)
          #   build_dir/toolchain-*/     ← build tree with .built stamps
          #
          cd "${WORKTREE}"
          tar czf /tmp/toolchain-cache.tar.gz \
            $(ls -d \
                staging_dir/toolchain-* \
                staging_dir/host \
                build_dir/toolchain-* \
              2>/dev/null || true)
          cd -

          echo "==> Building data image..."
          # FROM scratch → zero-overhead base; ADD auto-extracts the .tar.gz
          # Files land at /staging_dir/... and /build_dir/... inside the image.
          # On restore, docker cp extracts them to the correct host path.
          mkdir /tmp/toolchain-build-ctx
          mv /tmp/toolchain-cache.tar.gz /tmp/toolchain-build-ctx/
          cat > /tmp/toolchain-build-ctx/Dockerfile << 'DOCKERFILE'
          FROM scratch
          ADD toolchain-cache.tar.gz /toolchain/
          DOCKERFILE

          docker build \
            --no-cache \
            -f /tmp/toolchain-build-ctx/Dockerfile \
            -t "${TOOLCHAIN_IMAGE}" \
            /tmp/toolchain-build-ctx

          echo "==> Pushing to GHCR..."
          docker push "${TOOLCHAIN_IMAGE}"

          echo "Toolchain image pushed: ${TOOLCHAIN_IMAGE}"
          # Clean up the large context to recover disk space before the prune step
          rm -rf /tmp/toolchain-build-ctx
```

> [!NOTE]
> **`FROM scratch` + `ADD` path mechanics:** Docker's `ADD` with a `.tar.gz` file auto-extracts into the destination directory. `ADD toolchain-cache.tar.gz /toolchain/` means the contents of the archive land at `/toolchain/<archive-root>/...`. Since we tar from inside `$WORKTREE` with paths like `staging_dir/toolchain-*/...`, the image will contain `/toolchain/staging_dir/toolchain-*/...` and `/toolchain/build_dir/toolchain-*/...`. The restore `docker cp tc-seed:/toolchain/staging_dir "${WORKTREE}/staging_dir"` then maps perfectly.

> [!IMPORTANT]
> **Why `if: success()` and not `if: always()`?** We must never cache a toolchain from a failed build — it may be partially built. The `TOOLCHAIN_RESTORED != 'true'` guard prevents re-pushing an image we already pulled, keeping GHCR clean.

---

### 2. `app/scripts/engine/07-compile.sh`

Add a stamp-touching block at the very top, after the `cd`:

```bash
#!/bin/bash
set -eo pipefail

echo "==> Compiling..."
cd "$WORKTREE_DIR"

# ── Toolchain cache restoration ────────────────────────────────────────────────
# When the toolchain was restored from GHCR, the extracted files carry the
# timestamps from when they were archived (older than the freshly cloned source).
# make(1) uses mtime comparisons: if source files are newer than stamps, it
# will try to rebuild the toolchain even though nothing has changed.
#
# Fix: touch all stamp files to "now" (after source timestamps). This is safe
# because the cache key (profile.toml + source SHA + toolchain.mk + feeds.conf)
# mathematically guarantees the cached toolchain matches the current sources.
# A mtime lie cannot cause a stale build — only an unnecessary rebuild could,
# and we are preventing exactly that.
if [ "${TOOLCHAIN_RESTORED:-false}" = "true" ]; then
    echo "==> Toolchain restored from cache — fixing timestamps..."
    # staging_dir stamps (toolchain and host)
    find "$WORKTREE_DIR/staging_dir/" \
        \( -name ".built" -o -name ".configured" -o -name ".prepared" \) \
        -exec touch {} +
    # build_dir stamps for toolchain targets
    find "$WORKTREE_DIR/build_dir/toolchain-"* \
        \( -name ".built" -o -name ".configured" -o -name ".prepared" \) \
        -exec touch {} + 2>/dev/null || true
    echo "==> Timestamps fixed."
fi
# ──────────────────────────────────────────────────────────────────────────────

# Apply ccache max size — configurable via CCACHE_MAX_SIZE env var
ccache -M "${CCACHE_MAX_SIZE:-20G}"
# ... (rest of file unchanged)
```

---

## Edge Cases & Solutions

### Cache poisoning on toolchain input change

The hash covers `toolchain.mk` and the exact source SHA. Any upstream toolchain version bump or branch advance produces a new hash → cache miss → clean rebuild → new image pushed. Old images accumulate in GHCR (no automatic TTL).

**Mitigation:** Add a monthly cleanup workflow:
```yaml
# .github/workflows/prune-toolchain-cache.yml
on:
  schedule:
    - cron: '0 3 1 * *'   # 03:00 UTC on the 1st of each month
jobs:
  prune:
    runs-on: ubuntu-latest
    permissions:
      packages: write
    steps:
      - uses: actions/delete-package-versions@v5
        with:
          package-name: firmware-builder-toolchain-nanopi-r4s   # one per profile
          package-type: container
          min-versions-to-keep: 3
          token: ${{ secrets.GITHUB_TOKEN }}
```

### GHCR image visibility

For **public repos**, all pushed packages are public. If the toolchain image contains anything sensitive (it won't — it's just GCC and musl), set visibility explicitly in the GitHub UI under `Packages → Package settings → Change visibility`.

### `fresh_build` input bypasses the cache correctly

When `fresh_build: true`, the setup step runs `git reset --hard origin/$BRANCH`, which changes the worktree. The hash step runs after setup and uses the new `HEAD` SHA. If the commit is the same (force-push reset, not a new commit), the same cached image is restored. If it's a different commit, a cache miss occurs and the toolchain rebuilds. No special handling needed.

### Parallel profile builds don't conflict

Each profile gets a unique image name (`toolchain-nanopi-r4s`, `toolchain-<profile-b>`, etc.) and a unique hash tag. Matrix builds run in separate runners and never share a Docker daemon. No race conditions.

### `docker pull` failure modes

If GHCR is temporarily unavailable, `docker pull` fails and the `if` block falls through to the miss path — the build continues as a full build. The `|| true` / `2>/dev/null` guards in the restore step ensure a GHCR outage never fails the workflow.

### `FROM scratch` + gzip compatibility

Docker's `ADD` instruction auto-extracts `.tar.gz` files. This is supported in all Docker versions back to 1.0 (not a new BuildKit feature). The `FROM scratch` base produces an image with only the toolchain layer — no OS, no shell — which is correct for a pure data image.

### Disk space during the save step

The save step runs **before** `Reclaim Disk Space`, so Docker is still available. However, creating the tarball + docker build context requires temporary disk headroom. After a full build, available disk is typically 10–20 GB (artifacts are small). The toolchain tar is ~1.5–2.5 GB compressed. The build context copy adds another 1.5–2.5 GB temporarily. Peak usage: ~5 GB. This is within margin.

### Transfer speed (GHCR ↔ GitHub-hosted runners)

GitHub-hosted runners run in Azure datacenters in the same region as GHCR. Internal transfer rates are typically 200–500 MB/s. A 2 GB compressed layer takes **4–10 seconds** to pull. Pushing (after a successful miss) is similarly fast. This is far superior to GitHub's native cache (which uses the same infrastructure) because GHCR has no 10 GB quota cap.

---

## Step Ordering in `build.yml` (Final)

```
1.  Free Disk Space
2.  Checkout Builder Repository
3.  Restore OpenWrt Source Cache
4.  Restore Download Directory Cache
5.  Restore ccache
6.  Set up Docker Buildx
7.  Log in to GHCR                            ← NEW
8.  Build Docker Image (with layer cache)
9.  Disk Space Before Build
10. Setup Firmware Source
11. Save OpenWrt Source Cache
12. Calculate Toolchain Cache Hash             ← NEW (needs source/main/)
13. Restore Toolchain from GHCR               ← NEW (docker pull + docker cp)
14. Build Firmware                             ← MODIFIED (passes TOOLCHAIN_RESTORED)
15. Upload Firmware Artifacts
─── Post-build ────────────────────────────────────────────────────────────────
16. Save Toolchain to GHCR                    ← NEW  if: success() && !restored
17. Reclaim Disk Space for Cache Save          (existing — nukes Docker AFTER push)
18. Disk Space Before Cache Save
19. Save Download Directory Cache
20. Delete Download Cache Directory
21. Save ccache
```

---

## Verification Plan

### Run 1 (cold — expected: full build + push)

1. Trigger `workflow_dispatch` with default inputs.
2. Confirm step 12 prints a 16-character hex hash.
3. Confirm step 13 logs `"Cache MISS"`.
4. Confirm the full toolchain build runs (~40–60 min for aarch64).
5. Confirm step 16 logs `"Toolchain image pushed: ghcr.io/..."`.
6. In the repo's **Packages** tab, verify the container image appears with the hash tag.

### Run 2 (warm — expected: toolchain skip)

1. Trigger a second `workflow_dispatch` (no source changes).
2. Confirm step 13 logs `"Cache HIT"` and `"Toolchain extracted successfully."`.
3. Confirm step 16 is **skipped** (`TOOLCHAIN_RESTORED=true`).
4. Confirm `07-compile.sh` logs `"Toolchain restored from cache — fixing timestamps..."`.
5. Confirm the build completes **without** rebuilding `toolchain/install` targets in make output.
6. Total runtime should be < 15 min vs. ~60 min on a cold run.

### Run 3 (invalidation — expected: fresh rebuild)

1. Bump a package version in `profile.toml` (or merge a new commit to the upstream branch).
2. Confirm the hash in step 12 differs from Run 1.
3. Confirm a cache miss, full rebuild, and a new GHCR image tag.
