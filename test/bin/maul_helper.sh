#!/usr/bin/env bash

# Helper functions for testing maul.py

maul() {
    run ./run -q maul "$@"
}

# Creates a mock ABI structure for testing maul.py functions
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
