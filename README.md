# Owrt Firmware Builder

A robust, containerized builder for compiling custom OpenWrt firmware. It keeps your custom configuration separate from the upstream source, allowing you to easily update base versions without dealing with massive git conflicts.

For a deeper overview of the architecture and comprehensive implementation details, please read [design.md](design.md).

## Key Features

- **Official Package ABI Compatibility (`vermagic` Override):** Set `vermagic = "<hash>"` in `profile.toml` to align your kernel module hash with official OpenWrt/ImmortalWrt release snapshots. The build engine automatically intercepts kernel Makefile generation and purges stale out-of-tree kmod packages on incremental builds so official repository `kmod-*` packages install cleanly without `kernel=...` dependency mismatch errors.
- **Upstream Source Pinning (`tag` / `commit` / `branch`):** Pin device profiles to specific release tags (`tag = "v23.05.5"`), exact commit SHAs (`commit = "..."`), or tracking branches (`branch = "..."`). All profiles share a single lightweight object store with detached git worktrees.
- **Log & Package Name Obfuscation (`--obfuscate`):** Pass `--obfuscate` to redact sensitive package names, feed URLs, and directory paths (`***`) on public console stdout while writing complete unredacted diagnostic logs (`setup.log`, `download.log`, `build.log`) to encrypted archives.
- **Strict Feed Priorities & Dynamic Overlay Assembly:** Enforce custom feed priorities (`extra_feeds`) over upstream defaults and freshly inject profile overlay files (`files/`) on every build run.

## Quick Start (Local Build)

### 1. Start the Builder Workbench

The builder runs entirely inside a persistent Docker container to keep your host system clean.

```bash
docker compose up -d --build
docker compose exec builder bash
```

All subsequent commands should be run inside this container. The `builder` CLI tool is globally available.

### 2. Prepare and Build a Profile

Assuming you have a profile in `profiles/generic-x86`:

```bash
# Fetch source, apply patches, feeds, and install packages
builder setup --profile generic-x86

# Compile the firmware
builder build --profile generic-x86
```

Once complete, the compiled firmware images will be available in the `artifacts/generic-x86/` directory on your host machine.

### Other Useful Commands

- `builder menuconfig --profile <slug>`: Interactive OpenWrt configuration menu.
- `builder save-config --profile <slug>`: Save changes from menuconfig back to your profile.
- `builder clean-cache`: Clean up downloaded files and ccache to free up space.
- `builder save-patches --profile <slug>`: Save refreshed patches back to your profile.

## GitHub Actions CI

You can automate your builds using the provided GitHub Actions workflow.

### Setup Requirements

The workflow expects your device profiles to be stored in a separate, dedicated repository to keep your builder codebase generic and reusable. 

You need to configure the following repository secrets:
- `PROFILES_REPO`: The `user/repo` path to your profiles repository.
- `PROFILES_PAT`: A Personal Access Token with read access to the profiles repository.
- `BUILD_PASSWORD`: A strong password used to encrypt GitHub Actions caches (`source`, `dl`, `ccache`) and the final firmware artifacts, preventing potential leaks of custom proprietary code.

### Triggering Builds

1. Go to the **Actions** tab on your GitHub repository.
2. Select the **Build OpenWrt** workflow.
3. Click **Run workflow**.
4. You can specify a single profile slug (e.g., `generic-x86`) or leave it as `all` to build all available profiles dynamically.

The workflow leverages encrypted caching for source trees, toolchains, and `ccache` to massively accelerate remote builds while maintaining strict security.
