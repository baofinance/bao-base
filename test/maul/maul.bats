#!/usr/bin/env bats

load '../bats_helpers.sh'
load "maul_helpers.sh"

setup() {
  # Create temp dir for test outputs
  mkdir -p "$BATS_TEST_TMPDIR/out"
  export ABI_DIR="$BATS_TEST_TMPDIR/out"
}

teardown() {
  # Clean up temp directory
  rm -rf "$BATS_TEST_TMPDIR/out"
}

@test "maul shows help information if no commands given" {
  # Use the maul helper function directly
  run maul
  expect --status 1 --contains "usage:"
  expect --status 1 --contains "options:"
}

@test "maul shows help information" {
  # Use the maul helper function directly
  run maul --help
  expect --contains "usage:"
  expect --contains "options:"
}

@test "maul command shows function signature" {
  # Create mock ABI file for testing
  mkdir -p "$BATS_TEST_TMPDIR/out"
  cat >"$BATS_TEST_TMPDIR/out/ERC20.json" <<EOF
{
  "abi": [
    {
      "name": "transfer",
      "type": "function",
      "inputs": [
        {"name": "recipient", "type": "address"},
        {"name": "amount", "type": "uint256"}
      ],
      "outputs": [
        {"name": "success", "type": "bool"}
      ]
    }
  ]
}
EOF

  # Use the maul helper function - note that maul() already includes "run"
  run maul sig ERC20.transfer

  # Verify output contains correct signature
  expect --contains "transfer(address,uint256)"
  expect --contains "recipient: address"
  expect --contains "amount: uint256"
  expect --contains "success: bool"
}

@test "maul resolves 'baomultisig' to an address" {
  # Set required environment variables
  export PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  # Use the maul helper function with resolve command
  run maul -q address --of baomultisig

  # Check that the output is a valid Ethereum address
  expect --regexp "0x[a-fA-F0-9]{40}"
}

# @test "maul decodes known error" {
#   # Create mock ABI file for testing
#   mkdir -p "$BATS_TEST_TMPDIR/out"
#   cat >"$BATS_TEST_TMPDIR/out/TestContract.json" <<EOF
# {
#   "abi": [
#     {
#       "name": "InvalidValue",
#       "type": "error",
#       "inputs": [
#         {"name": "value", "type": "uint256"}
#       ]
#     }
#   ]
# }
# EOF

#   # Calculate error selector for InvalidValue(uint256)
#   local error_sig=$(cast keccak "InvalidValue(uint256)" 2>/dev/null | head -c 10)
#   echo "error_sig=$error_sig."
#   local error_data="${error_sig}000000000000000000000000000000000000000000000000000000000000002a"
#   echo "error_data=$error_data."

#   # Use maul helper function for decode command
#   maul decode "$error_data" TestContract

#   # Verify the error is properly decoded
#   expect --contains "InvalidV alue"
#   expect --contains "42"
# }

# @test "maul handles both signature formats" {
#   # Create mock ABI file
#   mkdir -p "$BATS_TEST_TMPDIR/out"
#   cat >"$BATS_TEST_TMPDIR/out/Token.json" <<EOF
# {
#   "abi": [
#     {
#       "name": "approve",
#       "type": "function",
#       "inputs": [
#         {"name": "spender", "type": "address"},
#         {"name": "amount", "type": "uint256"}
#       ],
#       "outputs": [
#         {"name": "success", "type": "bool"}
#       ]
#     }
#   ]
# }
# EOF

#   # Test with a full function signature using maul helper
#   run maul sig "transfer(address,uint256)"
#   expect --contains "transfer(address,uint256)"
#   expect --contains "address"
#   expect --contains "uint256"

#   # Test with Contract.function format
#   run maul sig Token.approve
#   expect --contains "approve(address,uint256)"
#   expect --contains "spender: address"
#   expect --contains "amount: uint256"
# }

# @test "maul formats different output types correctly" {
#   # Create mock ABI files for the test
#   mkdir -p "$BATS_TEST_TMPDIR/out"
#   cat >"$BATS_TEST_TMPDIR/out/MyContract.json" <<EOF
# {
#   "abi": [
#     {
#       "name": "isSomething",
#       "type": "function",
#       "inputs": [],
#       "outputs": [
#         {"name": "result", "type": "bool"}
#       ]
#     },
#     {
#       "name": "isSomethingElse",
#       "type": "function",
#       "inputs": [],
#       "outputs": [
#         {"name": "result", "type": "bool"}
#       ]
#     },
#     {
#       "name": "getNumber",
#       "type": "function",
#       "inputs": [],
#       "outputs": [
#         {"name": "value", "type": "uint256"}
#       ]
#     },
#     {
#       "name": "getAddress",
#       "type": "function",
#       "inputs": [],
#       "outputs": [
#         {"name": "addr", "type": "address"}
#       ]
#     }
#   ]
# }
# EOF

#   # Use the maul helper function to test formatting
#   run maul format 0x000000000000000000000000000000000000000000000000000000000000002a MyContract.getNumber
#   expect --contains "42"

#   # Test boolean result
#   run maul format 0x0 MyContract.isSomething
#   expect --contains "false"

#   run maul format 0x1 MyContract.isSomethingElse
#   expect --contains "true"

#   # Test address result
#   run maul format 0x5FbDB2315678afecb367f032d93F642f64180aa3 MyContract.getAddress
#   expect --contains "0x5FbDB2315678afecb367f032d93F642f64180aa3"
# }
