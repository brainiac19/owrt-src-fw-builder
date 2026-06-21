#!/bin/bash
set -eo pipefail

echo "Exporting artifacts..."
mkdir -p "/builder/artifacts/$PROFILE"
cp -r "$WORKTREE_DIR/bin/targets/"* "/builder/artifacts/$PROFILE/" || true
echo "Artifacts exported to /builder/artifacts/$PROFILE/"
