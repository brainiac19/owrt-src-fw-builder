#!/bin/bash
set -eo pipefail

if [[ "$FRESH" -eq 1 ]]; then
    export FRESH_SETUP=1
fi

"$BUILDER_ROOT/scripts/engine/fetch-source.sh"
"$BUILDER_ROOT/scripts/engine/apply-feeds.sh"
"$BUILDER_ROOT/scripts/engine/install-packages.sh"
"$BUILDER_ROOT/scripts/engine/apply-patches.sh"
"$BUILDER_ROOT/scripts/engine/assemble-files.sh"

echo "Setup complete for profile $PROFILE"
