# Firmware Builder Design Overview

Welcome to the Universal OpenWrt Firmware Builder! This document provides a simplified overview of how the tool works and how to use it. If you want a deep dive into the architectural reasoning, check out `IMPLEMENTATION.md`.

## Core Philosophy

**The upstream source is a build-time dependency, not your codebase.**

Instead of forking the massive OpenWrt repository and mixing your customizations into it, this builder keeps your configuration entirely separate. The repository contains ONLY your customizations. At build time, it fetches a clean upstream source, applies your changes on top, and compiles the firmware. 

This makes upgrading branches or switching upstream sources trivial and conflict-free.

## Architecture & Directory Layout

Everything device-specific lives in a "profile". The build engine itself is generic and has no hardcoded knowledge of any specific device.

```text
firmware-builder/
├── profiles/                     ← Mount point for device profiles (often from an external repository)
│   └── my-device/                ← One directory per device profile
│       ├── profile.toml          ← Core metadata (repo, branch/tag/commit, target, packages, vermagic, extra_feeds)
│       ├── config.seed           ← Base OpenWrt configuration (target, kernel)
│       ├── pkg-options/          ← Per-package configurations (e.g., Docker options)
│       ├── patches/              ← Custom patches for kernel or source
│       └── files/                ← Files to inject into the root filesystem
├── app/                          ← Builder components
│   ├── Dockerfile                ← Defines the builder container
│   ├── scripts/                  ← Engine scripts embedded into the image
│   └── shared/                   ← Opt-in shared utilities
├── .github/workflows/build.yml   ← CI workflow for automated remote building
└── docker-compose.yml            ← Runs the builder locally in an isolated environment
```

## How It Works

The system utilizes a persistent Docker "workbench" rather than forcing you to pollute your host OS. To optimize builds and save disk space, the container standardizes all paths to a `/builder` root:
- **Profiles:** Mounted from your repository (`/builder/profiles`).
- **Worktrees:** Multiple profiles share a single lightweight git object store (`/builder/source`).
- **Shared Caches:** Downloads (`/builder/dl`) and compiler objects (`/builder/ccache`) are shared across all profiles to drastically speed up subsequent builds.

### Key Engine Features & Nuanced Implementation Details

#### 1. Authoritative Vermagic Overriding & Stale kmod Purging (`vermagic`)
When building a custom kernel with out-of-tree patches, OpenWrt normally generates a unique MD5 hash (`LINUX_VERMAGIC`) from the sorted list of enabled kernel modules (`grep '=[ym]' $(LINUX_DIR)/.config.set | mkhash md5`). Any modification changes this hash, breaking compatibility with official OpenWrt/ImmortalWrt package repository `kmod-*` modules (`opkg`/`apk` will refuse to install official kernel modules due to `kernel=...` dependency mismatch).
To allow power users to install official kmod packages on top of custom-patched kernels without ABI errors, our builder implements an authoritative override engine in [`compile.sh`](file:///home/tim/mybuild/firmware-builder/app/scripts/engine/compile.sh):
- **Direct Profile Resolution:** `compile.sh` reads `vermagic = "..."` directly from `profile.toml` into `OVERRIDE_VERMAGIC` at the start of compilation.
- **Idempotent Makefile Interception:** Writing `CONFIG_LINUX_VERMAGIC` into `.config` is ignored by OpenWrt. Instead, `compile.sh` automatically patches `$WORKTREE_DIR/include/kernel-defaults.mk`, appending:
  ```makefile
  $(if $(OVERRIDE_VERMAGIC),printf '%s' '$(OVERRIDE_VERMAGIC)' > $(LINUX_DIR)/.vermagic)
  ```
  immediately after OpenWrt's natural `.vermagic` generation recipe line. Whenever `Kernel/Configure/Default` runs, our hook forces `.vermagic` to the official release hash.
- **Pre-Writing `.vermagic`:** Because `include/kernel.mk` evaluates `LINUX_VERMAGIC := $(shell cat $(LINUX_DIR)/.vermagic 2>/dev/null)` at Makefile parse time, `compile.sh` pre-writes existing `.vermagic` files across `build_dir/` before `make` starts so all package Makefiles immediately see the overridden hash.
- **Stale kmod Package & Stamp Purging (Incremental Build Protection):** On incremental builds where source code has not changed, OpenWrt's build system skips recompiling out-of-tree packages (such as `gpio-button-hotplug` or `nft-fullcone`), leaving behind stale `.apk`/`.ipk` packages compiled against older kernel hashes. Whenever `OVERRIDE_VERMAGIC` is active, `compile.sh` explicitly purges all existing `kmod-*.apk` and `kmod-*.ipk` files from `staging_dir/packages/` and `bin/targets/`, and deletes `.built`, `.pkgdir`, and `.installed` stamps for out-of-tree kernel modules. This forces GNU Make to repackage every enabled kmod against the overridden kernel dependency (`6.12.94~<OVERRIDE_VERMAGIC>-r1`), preventing repository solver errors during root filesystem generation.
- **Post-Build Verification:** After compilation completes, `compile.sh` scans all `.vermagic` files across `build_dir/` and outputs a prominent diagnostic summary (`[OK]` vs `[MISMATCH]`).

#### 2. Upstream Pinning: Branch, Tag, and Commit (`fetch-source.sh`)
Profiles define their upstream source in `profile.toml` using `repo` and one of `branch`, `tag`, or `commit`. The engine in [`fetch-source.sh`](file:///home/tim/mybuild/firmware-builder/app/scripts/engine/fetch-source.sh) handles each pinning strategy with optimal git performance:
- **Tag Pinning (`tag = "v23.05.5"`):** Clones only the target release tag shallowly (`git clone --depth=1 --branch "$TAG"`), ensuring reproducible release builds with minimal network and disk footprint.
- **Commit SHA Pinning (`commit = "..."`):** Shallowly clones the target branch (`--depth=1 -b "$BRANCH"`), fetches the exact commit SHA (`git fetch --depth=1 origin "$COMMIT"`), and performs a hard reset (`git reset --hard FETCH_HEAD`) to lock the tree to an immutable revision.
- **Branch Tracking (`branch = "openwrt-25.12"`):** Shallowly clones or fetches the tip of the remote branch (`git reset --hard "origin/$BRANCH"`).
- **Detached Worktree Isolation:** Rather than duplicating git repositories across profiles, all profiles share a single object store (`/builder/source/main`) and check out isolated worktrees (`git worktree add --detach /builder/source/worktrees/$PROFILE HEAD`).

#### 3. Log & Package Name Obfuscation (`filter_logs.py`)
To protect proprietary customizations, internal feed repositories, and custom package names during public CI builds, all builder commands (`setup`, `download`, `compile`) support an opt-in `--obfuscate` flag:
- **Real-time Console Redaction:** When enabled (`OBFUSCATE_LOGS=1`), [`filter_logs.py`](file:///home/tim/mybuild/firmware-builder/app/scripts/engine/filter_logs.py) intercepts stdout stream lines via compiled regular expressions, rewriting:
  - Recursive make targets (`make[d] -C <prefix>/<pkg> ...`) $\rightarrow$ `make[d] -C <prefix>/*** ...`
  - Feed updates (`Updating feed '<name>' from '<url>'`) $\rightarrow$ `Updating feed '***' from '***'`
  - Package installations (`Installing package '<pkg>'`) $\rightarrow$ `Installing package '***'`
- **Unredacted Diagnostic Artifacts:** While console stdout is sanitized for public CI logs, the full unredacted log stream is written concurrently to `BUILD_LOG_FILE` (`setup.log`, `download.log`, `build.log`). In CI, these logs are packed into a password-encrypted 7-zip archive so developers can debug failures without exposing package names in public build logs.

#### 4. Dynamic Overlay Assembly & Strict Feed Prioritization
- **Strict Feed Priorities:** Custom `extra_feeds` defined in `profile.toml` are prepended to OpenWrt feeds and enforced with `--force-overwrite` during `install-packages.sh`, allowing custom forks (e.g., `luci-app-mosdns`) to cleanly override upstream packages.
- **Dynamic File Injection:** Profile overlay files (`files/`) and shared base scripts (`uci-defaults`, `preinit`) are freshly assembled into OpenWrt's target overlay directory on every build run so modified configurations take effect immediately without requiring a full clean.

## Example Usage (Local)

Here is a typical workflow to create, configure, and build a profile locally.

### 1. Start the Workbench

Bring up the Docker container in the background and open a shell inside it:

```bash
docker compose up -d --build
docker compose exec builder bash
```

*Note: The `builder` CLI tool is globally available inside this shell.*

### 2. Prepare the Profile

Assuming you have a profile named `generic-x86`, run `setup` to fetch the source code, apply feeds, and install packages:

```bash
builder setup --profile generic-x86
```

### 3. Customize Firmware (Interactive)

Launch the standard OpenWrt configuration interface:

```bash
builder menuconfig --profile generic-x86
```

Navigate the menus, select the packages you want, adjust target settings, and save and exit.

### 4. Save Your Configuration

Once you're happy with your changes in `menuconfig`, extract them back into your `profile.toml` and `config.seed` so they are tracked in version control:

```bash
builder save-config --profile generic-x86
```

### 5. Compile

Build the firmware image:

```bash
builder build --profile generic-x86
```

When the build completes, the compiled firmware images will automatically appear on your host machine in the `artifacts/generic-x86/` directory! 

*(Note: The build command natively detects changes in your `profile.toml` and will automatically re-apply feeds and install packages on the fly.)*

### 6. Start Fresh or Build Another Device

If you want to wipe the workspace and update to the latest upstream changes before building, use the `--fresh` flag:
```bash
builder build --profile generic-x86 --fresh
```

## Automated CI/CD (GitHub Actions)

This repository includes a robust GitHub Actions workflow (`.github/workflows/build.yml`) that allows you to trigger firmware builds directly from the GitHub UI using your exact Docker environment.

The CI workflow is designed around strict security and decoupling:
- **Decoupled Profiles:** The builder expects device profiles to be hosted in a separate repository (configured via `PROFILES_REPO` and `PROFILES_PAT` secrets). This keeps the builder engine completely agnostic and public, while your device configurations remain private.
- **Obfuscated Public Logs & Complete Diagnostic Artifacts:** All CI build steps (`setup`, `download`, `compile`) automatically run with `--obfuscate` so custom package names and feed URLs are redacted (`***`) in public runner logs. Full unobfuscated diagnostic logs (`setup.log`, `download.log`, `build.log`) are captured inside the password-encrypted 7-zip artifact archive.
- **Manual Triggering:** Go to the "Actions" tab on GitHub, select "Build OpenWrt", and click "Run workflow". You can enter `all` to build the entire matrix, or type a specific profile slug (like `generic-x86`) to only spin up runners for that specific device!
- **Encrypted Caches:** To prevent leaks of custom packages or proprietary code through public GitHub Actions caches, the workflow compresses and heavily encrypts the `source`, `dl`, and `ccache` caches using `age` and a secure `BUILD_PASSWORD`.
- **Toolchain Caching:** To bypass slow GitHub cache restoration, the compiled toolchain is packed into a Docker image and pushed to GHCR, making subsequent rebuilds astonishingly fast.
- **Encrypted Artifacts:** The final firmware images are compressed and encrypted with a password via 7-zip before being uploaded as artifacts.
