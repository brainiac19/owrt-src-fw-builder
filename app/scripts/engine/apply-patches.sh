#!/bin/bash
set -eo pipefail

echo "==> Applying patches..."

KERNEL_TARGET=$(python3 -c '
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(sys.argv[1], "rb") as f:
    print(tomllib.load(f).get("kernel_target", ""))
' "$PROFILE_DIR/profile.toml")
KERNEL_PATCHVER=""

if [ -n "$KERNEL_TARGET" ]; then
    MK="$WORKTREE_DIR/target/linux/$KERNEL_TARGET/Makefile"
    if [ -f "$MK" ]; then
        KERNEL_PATCHVER=$(grep -oP 'KERNEL_PATCHVER\s*:=\s*\K[0-9]+\.[0-9]+' "$MK" | head -1)
    fi
fi

if [ -z "$KERNEL_PATCHVER" ]; then
    echo "Warning: Could not auto-detect kernel version. Guessing 6.12 or fallback."
    KERNEL_PATCHVER="6.12"
fi

if [ -d "$PROFILE_DIR/patches/kernel" ]; then
    for patch in "$PROFILE_DIR/patches/kernel/"*.patch; do
        [ -f "$patch" ] || continue
        dest="$WORKTREE_DIR/target/linux/$KERNEL_TARGET/patches-$KERNEL_PATCHVER/"
        mkdir -p "$dest"
        cp "$patch" "$dest"
        echo "Copied kernel patch: $(basename "$patch")"
    done
fi

# ── Shared source patches (applied to every profile) ─────────────────────────
SHARED_PATCHES_DIR="$BUILDER_ROOT/shared/patches/source"
if [ -d "$SHARED_PATCHES_DIR" ]; then
    for patch in "$SHARED_PATCHES_DIR/"*.patch; do
        [ -f "$patch" ] || continue
        if patch --dry-run -p1 -d "$WORKTREE_DIR" --silent < "$patch" 2>/dev/null; then
            patch -p1 -d "$WORKTREE_DIR" < "$patch"
            echo "Applied shared patch: $(basename "$patch")"
        elif patch --dry-run -p1 -d "$WORKTREE_DIR" --reverse --silent < "$patch" 2>/dev/null; then
            echo "Already applied — skipping: $(basename "$patch")"
        else
            echo "ERROR: Shared patch cannot apply cleanly: $(basename "$patch")"
            exit 1
        fi
    done
fi

if [ -d "$PROFILE_DIR/patches/source" ]; then
    for patch in "$PROFILE_DIR/patches/source/"*.patch; do
        [ -f "$patch" ] || continue
        if patch --dry-run -p1 -d "$WORKTREE_DIR" --silent < "$patch" 2>/dev/null; then
            patch -p1 -d "$WORKTREE_DIR" < "$patch"
            echo "Applied source patch: $(basename "$patch")"
        elif patch --dry-run -p1 -d "$WORKTREE_DIR" --reverse --silent < "$patch" 2>/dev/null; then
            echo "Already applied — skipping: $(basename "$patch")"
        else
            echo "ERROR: Cannot apply cleanly: $(basename "$patch")"
            echo "To fix interactively:"
            echo "  docker compose exec builder bash"
            echo "  cd /builder/source/worktrees/$PROFILE"
            echo "  quilt push -f       # force-apply up to the failing patch"
            echo "  # edit the reject files (.rej)"
            echo "  quilt refresh       # update the patch with your fixes"
            echo "  builder save-patches --profile $PROFILE"
            exit 1
        fi
    done
fi

# ── Vermagic Override Injection ──────────────────────────────────────────────
# If profile.toml defines `vermagic`, we inject an override into the OpenWrt
# build system so the kernel's .vermagic file is forced to the official hash,
# allowing official kmod packages to be installed on a custom-patched kernel.
#
# How vermagic works in OpenWrt/ImmortalWrt:
#   During kernel build, include/kernel-defaults.mk runs:
#     grep '=[ym]' $(LINUX_DIR)/.config.set | LC_ALL=C sort | mkhash md5 > $(LINUX_DIR)/.vermagic
#   This hash is embedded in the kernel package version string (e.g. 6.12.94~9695dbb0-r1).
#   Every kmod package checks this hash at install time — if they differ, install fails.
#
# Our fix: add an OVERRIDE_VERMAGIC check in kernel-defaults.mk so when
# OVERRIDE_VERMAGIC is set (passed via `make OVERRIDE_VERMAGIC=...`), the hash
# is forced to the desired value instead of being computed from the local config.
VERMAGIC_OVERRIDE=$(python3 -c '
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(sys.argv[1], "rb") as f:
    print(tomllib.load(f).get("vermagic", ""))
' "$PROFILE_DIR/profile.toml" 2>/dev/null || true)

KERNEL_DEFAULTS_MK="$WORKTREE_DIR/include/kernel-defaults.mk"

if [ -n "$VERMAGIC_OVERRIDE" ] && [ -f "$KERNEL_DEFAULTS_MK" ]; then
    echo "==> Patching include/kernel-defaults.mk for vermagic override..."
    # Check if already patched to be idempotent
    if ! grep -q 'OVERRIDE_VERMAGIC' "$KERNEL_DEFAULTS_MK"; then
        # Inject our hook immediately after the copyright header block.
        # Using sed to insert after the last leading comment block line.
        # We add it at the very top of the file after the license header,
        # which makes the Kernel/FixVermagic define available for use
        # in Kernel/Configure/Default recipes.
        python3 - "$KERNEL_DEFAULTS_MK" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

TAB = '\t'

injection = (
    "\n"
    "# \u2500\u2500 firmware-builder: vermagic override support \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n"
    "# When OVERRIDE_VERMAGIC is passed to make, the kernel .vermagic file\n"
    "# is forced to that value so official kmod packages remain installable.\n"
    "ifdef OVERRIDE_VERMAGIC\n"
    "  define Kernel/SetVermagic\n"
    + TAB + "printf '%s' '$(OVERRIDE_VERMAGIC)' > $(LINUX_DIR)/.vermagic\n"
    + TAB + "@echo 'firmware-builder: vermagic forced to $(OVERRIDE_VERMAGIC)'\n"
    "  endef\n"
    "else\n"
    "  define Kernel/SetVermagic\n"
    "  endef\n"
    "endif\n"
    "# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n"
)

# Strategy 1: find the .vermagic write line and append our call right after it.
# The recipe line looks like:
#   \tgrep '=[ym]' $(LINUX_DIR)/.config.set | LC_ALL=C sort | $(MKHASH) md5 > $(LINUX_DIR)/.vermagic
# We insert $(call Kernel/SetVermagic) on the next line inside the define block.
vermagic_pattern = re.compile(r'(\t[^\n]*\.vermagic[^\n]*\n)', re.MULTILINE)
match = vermagic_pattern.search(content)
if match:
    pos = match.end()
    content = content[:pos] + TAB + '$(call Kernel/SetVermagic)\n' + content[pos:]
    print("  Found .vermagic write line — injected call after it.")
else:
    # Strategy 2: couldn't find the exact recipe line.
    # This is expected on some OpenWrt versions where the line is in a different file.
    # The OVERRIDE_VERMAGIC env var will still be passed to make; compile.sh handles
    # the build_dir injection as the primary fallback.
    print("  WARNING: .vermagic write line not found in kernel-defaults.mk.")
    print("  compile.sh build_dir injection will be the primary override mechanism.")

# Always prepend the macro definition block (must come before any call)
content = injection + content

with open(path, 'w') as f:
    f.write(content)

print(f"  Patched {path}")
PYEOF
        echo "  kernel-defaults.mk patched for vermagic override."
    else
        echo "  kernel-defaults.mk already patched — skipping."
    fi
elif [ -n "$VERMAGIC_OVERRIDE" ] && [ ! -f "$KERNEL_DEFAULTS_MK" ]; then
    echo "  WARNING: vermagic override set but $KERNEL_DEFAULTS_MK not found."
    echo "  The vermagic will be forcibly written in compile.sh via build_dir injection."
fi
# ─────────────────────────────────────────────────────────────────────────────
