#!/usr/bin/env bash

# Path to maul script
MAUL_PATH="bin/maul/maul.py"

# Setup function that runs before each test
setup() {
  # Create a temporary directory for test artifacts
  BATS_TMPDIR=$(mktemp -d)
  export BATS_TMPDIR

  # Mock log directory for deploy-local.log
  mkdir -p "$BATS_TMPDIR/log"
  echo '{"addresses": {"testwallet": "0x1234567890123456789012345678901234567890"}}' >"$BATS_TMPDIR/log/deploy-local.log"

  # Save current directory
  INITIAL_PWD=$PWD

  # Set ABI_DIR to test fixtures
  export ABI_DIR="$BATS_TMPDIR/out"
  mkdir -p "$ABI_DIR"

  # Create test ABI fixtures
  create_test_abis

  # Set test private key
  export PRIVATE_KEY="0x1111111111111111111111111111111111111111111111111111111111111111"
}

# Teardown function that runs after each test
teardown() {
  # Return to initial directory
  cd "$INITIAL_PWD" || return

  # Clean up temporary directory
  rm -rf "$BATS_TMPDIR"
}

# Create test ABI files
create_test_abis() {
  # Create ERC20 test ABI
  cat >"$ABI_DIR/ERC20.json" <<EOF
{
  "abi": [
    {
      "type": "function",
      "name": "balanceOf",
      "inputs": [{"name": "account", "type": "address"}],
      "outputs": [{"name": "", "type": "uint256"}],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "transfer",
      "inputs": [
        {"name": "recipient", "type": "address"},
        {"name": "amount", "type": "uint256"}
      ],
      "outputs": [{"name": "", "type": "bool"}],
      "stateMutability": "nonpayable"
    },
    {
      "type": "error",
      "name": "InsufficientBalance",
      "inputs": [
        {"name": "available", "type": "uint256"},
        {"name": "required", "type": "uint256"}
      ]
    }
  ]
}
EOF

  # Create MockToken test ABI
  cat >"$ABI_DIR/MockToken.json" <<EOF
{
  "abi": [
    {
      "type": "function",
      "name": "grantRoles",
      "inputs": [
        {"name": "to", "type": "address"},
        {"name": "roleId", "type": "uint256"}
      ],
      "outputs": [],
      "stateMutability": "nonpayable"
    },
    {
      "type": "function",
      "name": "MINTER_ROLE",
      "inputs": [],
      "outputs": [{"name": "", "type": "uint256"}],
      "stateMutability": "view"
    }
  ]
}
EOF
}

# Helper to mock command execution
mock_command() {
  local cmd="$1"
  local output="$2"
  local status="${3:-0}"

  # Create a temporary mock script
  cat >"$BATS_TMPDIR/mock_$cmd" <<EOF
#!/bin/bash
echo "$output"
exit $status
EOF

  chmod +x "$BATS_TMPDIR/mock_$cmd"
  export PATH="$BATS_TMPDIR:$PATH"
}

# Helper to assert output contains a string
assert_output_contains() {
  local expected="$1"
  echo "$output" | grep -q "$expected" || {
    echo "Expected output to contain: $expected"
    echo "Actual output: $output"
    return 1
  }
}

# Mock anvil RPC response
mock_anvil() {
  mock_command "anvil" "Listening on 127.0.0.1:8545"
}

# Mock cast for various operations
mock_cast_balance() {
  mock_command "cast" "1000000000000000000" # 1 ETH in wei
}

mock_cast_to_wei() {
  mock_command "cast" "1000000000000000000" # 1 ETH in wei
}

mock_cast_from_wei() {
  mock_command "cast" "1.0" # 1.0 ETH
}

mock_cast_rpc() {
  mock_command "cast" "Success"
}
