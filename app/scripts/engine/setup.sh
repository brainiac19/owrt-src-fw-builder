#!/bin/bash
set -eo pipefail

if [[ "$FRESH" -eq 1 ]]; then
    export FRESH_SETUP=1
fi

"$BUILDER_ROOT/scripts/engine/01-fetch-source.sh"
"$BUILDER_ROOT/scripts/engine/02-apply-feeds.sh"
"$BUILDER_ROOT/scripts/engine/03-install-packages.sh"
"$BUILDER_ROOT/scripts/engine/04-apply-patches.sh"
"$BUILDER_ROOT/scripts/engine/05-assemble-files.sh"

echo "Setup complete for profile $PROFILE"
