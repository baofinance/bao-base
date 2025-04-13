#!/usr/bin/env bats

load '../bats_helpers.sh'
load "maul_helpers.sh"

setup() {
  # Create temp dir for test outputs
  mkdir -p "$BATS_TEST_TMPDIR/out"
  export ABI_DIR="$BATS_TEST_TMPDIR/out"

  # Create common mock ABI files that multiple tests will need
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
  # No need to create ERC20.json here since it's now in setup()

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

@test "maul resolves multiple address formats correctly" {
  export PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  # Test hex address passthrough
  run maul address --of 0x1234567890123456789012345678901234567890
  expect --contains "0x1234567890123456789012345678901234567890"

  # Test 'me' special case with private key
  run maul address --of me
  expect --regexp "0x[a-fA-F0-9]{40}"

  # Test environment variable passthrough when no resolution is possible
  run maul address --of unknownname
  expect --contains "unknownname"
}

@test "maul sig handles event signatures" {
  # Create mock ABI file with event
  mkdir -p "$BATS_TEST_TMPDIR/out"
  cat >"$BATS_TEST_TMPDIR/out/Events.json" <<EOF
{
  "abi": [
    {
      "name": "Transfer",
      "type": "event",
      "inputs": [
        {"name": "from", "type": "address", "indexed": true},
        {"name": "to", "type": "address", "indexed": true},
        {"name": "value", "type": "uint256", "indexed": false}
      ]
    }
  ]
}
EOF

  run maul sig --event Events.Transfer
  expect --contains "Transfer(address,address,uint256)"
  expect --contains "from: address"
  expect --contains "to: address"
  expect --contains "value: uint256"
}

@test "maul shows appropriate error for nonexistent ABI file" {
  run maul sig NonExistentContract.someFunction
  expect --status 1 --contains "error: Contract ABI file not found"
}

@test "maul shows appropriate error for nonexistent function" {
  # Create mock ABI file with a function
  mkdir -p "$BATS_TEST_TMPDIR/out"
  cat >"$BATS_TEST_TMPDIR/out/MockContract.json" <<EOF
{
  "abi": [
    {
      "name": "existingFunction",
      "type": "function",
      "inputs": [],
      "outputs": []
    }
  ]
}
EOF

  run maul sig MockContract.nonExistentFunction
  expect --status 1 --contains "error: Function nonExistentFunction not found"
}

@test "maul parses complex function signatures correctly" {
  mkdir -p "$BATS_TEST_TMPDIR/out"
  cat >"$BATS_TEST_TMPDIR/out/Complex.json" <<EOF
{
  "abi": [
    {
      "name": "complexFunction",
      "type": "function",
      "inputs": [
        {"name": "addressArray", "type": "address[]"},
        {"name": "amountStruct", "type": "tuple", "components": [
          {"name": "value", "type": "uint256"},
          {"name": "decimals", "type": "uint8"}
        ]},
        {"name": "active", "type": "bool"}
      ],
      "outputs": [
        {"name": "status", "type": "bytes32"}
      ]
    }
  ]
}
EOF

  run maul sig Complex.complexFunction
  expect --contains "complexFunction(address[],(uint256,uint8),bool)"
  expect --contains "addressArray: address[]"
  expect --contains "amountStruct: tuple"
  expect --contains "active: bool"
  expect --contains "status: bytes32"
}

@test "maul handles chain selection with --chain flag" {
  run maul --chain arbitrum address --of wsteth
  expect --regexp "0x[a-fA-F0-9]{40}"

  export PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  run maul address --of me
  expect --regexp "0x[a-fA-F0-9]{40}"

}

@test "maul supports quiet mode with -q flag" {
  # No need to create ERC20.json here since it's now in setup()

  run maul -q sig ERC20.transfer
  # In quiet mode, should only output essential information
  expect --contains "transfer(address,uint256)"
  # Should not contain debug info
  expect --not --contains "DEBUG:"
  expect --not --contains "WARN:"
  expect --not --contains "INFO "
  expect --not --contains "INFO1:"
  expect --not --contains "INFO2:"
  expect --not --contains "INFO3:"
  expect --not --contains "INFO4:"
}

@test "maul supports multiple verbosity levels" {
  # Test without verbosity flag (basic output)
  run maul sig ERC20.transfer
  expect --contains "transfer(address,uint256)"
  expect --contains "INFO:"
  expect --not --contains "INFO1:"
  expect --not --contains "INFO2:"
  expect --not --contains "INFO3:"
  expect --not --contains "INFO4:"

  # Test with -v (should include INFO level messages)
  run maul -v sig ERC20.transfer
  expect --contains "transfer(address,uint256)"
  expect --contains "INFO1:"
  expect --not --contains "INFO2:"
  expect --not --contains "INFO3:"
  expect --not --contains "INFO4:"

  # Test with -vv (should include DEBUG level messages)
  run maul -vv sig ERC20.transfer
  expect --contains "transfer(address,uint256)"
  expect --contains "INFO2:"
  expect --not --contains "INFO3:"
  expect --not --contains "INFO4:"

  # Test with -vvv (should include TRACE level messages - even more details)
  run maul -vvv sig ERC20.transfer
  expect --contains "transfer(address,uint256)"
  expect --contains "INFO3:"
  expect --not --contains "INFO4:"

  # Test with -vvvv (maximum verbosity - full command details)
  run maul -vvvv sig ERC20.transfer
  expect --contains "transfer(address,uint256)"
  expect --contains "INFO4:"
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
