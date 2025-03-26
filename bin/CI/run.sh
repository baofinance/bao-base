#!/usr/bin/env bash
set -euo pipefail

THIS=$(basename "$0" | cut -d. -f1)
# shellcheck disable=SC2154 # we don't need to check if the variable is set
DEP_DIR="$BAO_BASE_BIN_DIR/CI"

EVENT=$DEP_DIR/ubuntu_workflow_dispatch_current.json
WORKFLOW_FILE=local-test-foundry.yml
WORKFLOW_DIR=./cache

mkdir -p $WORKFLOW_DIR
echo "replacing \$BAO_BASE with ./$BAO_BASE"
# shellcheck disable=SC2154 # we don't need to check if the variable is set
sed "s|\$BAO_BASE|./$BAO_BASE|g" "$DEP_DIR/$WORKFLOW_FILE" > "$WORKFLOW_DIR/$WORKFLOW_FILE"

echo act -P ubuntu-latest=-self-hosted -W $WORKFLOW_DIR/$WORKFLOW_FILE -e "$EVENT" "$@"
$BAO_BASE_BIN_DIR/act -P ubuntu-latest=-self-hosted -W $WORKFLOW_DIR/$WORKFLOW_FILE -e "$EVENT" "$@"
