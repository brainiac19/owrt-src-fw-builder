#!/bin/bash
set -eo pipefail

if [[ "$FRESH" -eq 1 || ! -d "$WORKTREE_DIR" ]]; then
    export FRESH_SETUP=1
    "$BUILDER_ROOT/scripts/engine/setup.sh"
else
    # Always re-apply feeds, install packages, and reassemble files so profile changes are instantly reflected!
    "$BUILDER_ROOT/scripts/engine/apply-feeds.sh"
    "$BUILDER_ROOT/scripts/engine/install-packages.sh"
    rm -rf "$WORKTREE_DIR/files"
    "$BUILDER_ROOT/scripts/engine/assemble-files.sh"
fi

"$BUILDER_ROOT/scripts/engine/load-config.sh"
"$BUILDER_ROOT/scripts/engine/download.sh"
"$BUILDER_ROOT/scripts/engine/compile.sh"
"$BUILDER_ROOT/scripts/engine/export-artifacts.sh"
