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
│       ├── profile.toml          ← Core metadata (repo, branch, target, packages, extra_feeds)
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

### Key Engine Features
- **Strict Feed Priorities:** Custom `extra_feeds` defined in `profile.toml` are strictly enforced to override upstream OpenWrt defaults, allowing you to seamlessly pull in conflicting custom forks (e.g., `luci-app-mosdns`).
- **Aggressive Parallelism:** Compilations always run with maximum CPU cores (`$(nproc)`). If a build fails, it immediately aborts with a printout of the exact debug command you need, instead of silently falling back to a multi-hour single-core debug build.

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
- **Manual Triggering:** Go to the "Actions" tab on GitHub, select "Build OpenWrt", and click "Run workflow". You can enter `all` to build the entire matrix, or type a specific profile slug (like `generic-x86`) to only spin up runners for that specific device!
- **Encrypted Caches:** To prevent leaks of custom packages or proprietary code through public GitHub Actions caches, the workflow compresses and heavily encrypts the `source`, `dl`, and `ccache` caches using `age` and a secure `BUILD_PASSWORD`.
- **Toolchain Caching:** To bypass slow GitHub cache restoration, the compiled toolchain is packed into a Docker image and pushed to GHCR, making subsequent rebuilds astonishingly fast.
- **Encrypted Artifacts:** The final firmware images are compressed and encrypted with a password via 7-zip before being uploaded as artifacts.
