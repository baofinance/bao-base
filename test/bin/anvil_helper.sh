#!/usr/bin/env bash

# Helper functions for testing anvil.py

maul() {
    run ./run -q anvil "$@"
}

# Creates a mock ABI structure for testing anvil.py functions
create_mock_abi() {
    local contract_name="$1"
    local content="$2"

    mkdir -p "$BATS_TEST_TMPDIR/out"
    cat > "$BATS_TEST_TMPDIR/out/${contract_name}.json" << EOF
{
  "abi": $content
}
EOF
}
