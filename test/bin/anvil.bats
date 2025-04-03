#!/usr/bin/env bats

load '../bats_helpers.sh'
load 'anvil_helper.sh'

setup() {
  # Create temp dir for test outputs
  mkdir -p "$BATS_TEST_TMPDIR/out"
}

teardown() {
  teardown_test
}

@test "anvil.py shows help information" {
  run_anvil --help
  expect --head "usage: anvil.py"

}

@test "anvil.py sig command shows function signature" {
  # Create mock ABI file for testing
  mkdir -p "$BATS_TEST_TMPDIR/out"
  cat > "$BATS_TEST_TMPDIR/out/ERC20.json" <<EOF
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

  # Run the sig command using our mock directory
  ORIG_DIR=$(pwd)
  cd "$BATS_TEST_TMPDIR"
  export abi_dir="./out"
  run_anvil sig ERC20.transfer

  # Verify output contains correct signature
  assert_output --partial "signature for ERC20.transfer is \"transfer(address,uint256)\""
  assert_output --partial "Input Parameters:"
  assert_output --partial "recipient: address"
  assert_output --partial "amount: uint256"
  assert_output --partial "Return Values:"
  assert_output --partial "success: bool"

  cd "$ORIG_DIR"
  assert_success
}

@test "anvil.py address_of resolves 'me' to an address" {
  # Override the PRIVATE_KEY environment variable
  export PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" # Sample private key (not a real one)

  run_anvil_silent_python_code "
import sys
sys.path.append('./bin')
from anvil import address_of
print(address_of('mainnet', 'me'))
"
  # Check that the output is a valid Ethereum address
  assert_output --regexp "0x[a-fA-F0-9]{40}"
  assert_success
}

@test "anvil.py decode_custom_error decodes known error" {
  # Create mock ABI file for testing
  mkdir -p "$BATS_TEST_TMPDIR/out"
  cat > "$BATS_TEST_TMPDIR/out/TestContract.json" <<EOF
{
  "abi": [
    {
      "name": "InvalidValue",
      "type": "error",
      "inputs": [
        {"name": "value", "type": "uint256"}
      ]
    }
  ]
}
EOF

  # Calculate error selector for InvalidValue(uint256)
  local error_sig=$(cast keccak "InvalidValue(uint256)" 2>/dev/null | head -c 10)
  local error_data="${error_sig}000000000000000000000000000000000000000000000000000000000000002a"

  # Run decode_custom_error with our error data
  ORIG_DIR=$(pwd)
  cd "$BATS_TEST_TMPDIR"
  export abi_dir="./out"
  run_anvil_silent_python_code "
import sys
sys.path.append('$ORIG_DIR/bin')
from anvil import decode_custom_error
decoded, raw = decode_custom_error('$error_data')
print(decoded)
"

  # Verify the error is properly decoded with the value 42 (0x2a)
  assert_output --partial "Error: InvalidValue"
  assert_output --partial "value=42"

  cd "$ORIG_DIR"
  assert_success
}

@test "anvil.py parse_sig handles both signature formats" {
  # Create mock ABI file
  mkdir -p "$BATS_TEST_TMPDIR/out"
  cat > "$BATS_TEST_TMPDIR/out/Token.json" <<EOF
{
  "abi": [
    {
      "name": "approve",
      "type": "function",
      "inputs": [
        {"name": "spender", "type": "address"},
        {"name": "amount", "type": "uint256"}
      ],
      "outputs": [
        {"name": "success", "type": "bool"}
      ]
    }
  ]
}
EOF

  ORIG_DIR=$(pwd)
  cd "$BATS_TEST_TMPDIR"
  export abi_dir="./out"

  # Test with a full function signature
  run_anvil_silent_python_code "
import sys
sys.path.append('$ORIG_DIR/bin')
from anvil import parse_sig
sig, param_types = parse_sig('mainnet', 'transfer(address,uint256)')
print(f'Signature: {sig}')
print(f'Param types: {param_types}')
"

  assert_output --partial "Signature: transfer(address,uint256)"
  assert_output --partial "Param types: ['address', 'uint256']"

  # Test with Contract.function format
  run_anvil_silent_python_code "
import sys
sys.path.append('$ORIG_DIR/bin')
from anvil import parse_sig
sig, param_types = parse_sig('mainnet', 'Token.approve')
print(f'Signature: {sig}')
print(f'Param types: {param_types}')
"

  assert_output --partial "Signature: approve(address,uint256)"
  assert_output --partial "Param types: ['address', 'uint256']"

  cd "$ORIG_DIR"
  assert_success
}

@test "anvil.py set_verbosity correctly sets log levels" {
  run_anvil_silent_python_code "
import sys
import logging
sys.path.append('./bin')
from anvil import set_verbosity, logger

# Test different verbosity levels
print('Testing level 0:')
set_verbosity(0)
print(f'Logger level: {logger.level}')
print(f'Is WARNING enabled: {logger.isEnabledFor(logging.WARNING)}')
print(f'Is INFO enabled: {logger.isEnabledFor(logging.INFO)}')

print('\\nTesting level 1:')
set_verbosity(1)
print(f'Logger level: {logger.level}')
print(f'Is INFO enabled: {logger.isEnabledFor(logging.INFO)}')
print(f'Is DEBUG enabled: {logger.isEnabledFor(logging.DEBUG)}')

print('\\nTesting level 2:')
set_verbosity(2)
print(f'Logger level: {logger.level}')
print(f'Is DEBUG enabled: {logger.isEnabledFor(logging.DEBUG)}')
"

  # Check level 0 (WARNING)
  assert_output --partial "Testing level 0:"
  assert_output --partial "Is WARNING enabled: True"
  assert_output --partial "Is INFO enabled: False"

  # Check level 1 (INFO)
  assert_output --partial "Testing level 1:"
  assert_output --partial "Is INFO enabled: True"
  assert_output --partial "Is DEBUG enabled: False"

  # Check level 2 (DEBUG)
  assert_output --partial "Testing level 2:"
  assert_output --partial "Is DEBUG enabled: True"

  assert_success
}

@test "anvil.py format_call_result formats different output types correctly" {
  run_anvil_silent_python_code "
import sys
sys.path.append('./bin')
from anvil import format_call_result

# Test integer result
print('Integer result:')
print(format_call_result('0x000000000000000000000000000000000000000000000000000000000000002a'))

# Test boolean result
print('\\nBoolean results:')
print(format_call_result('0x0', 'MyContract.isSomething'))
print(format_call_result('0x1', 'MyContract.isSomethingElse'))

# Test address result
print('\\nAddress result:')
print(format_call_result('0x5FbDB2315678afecb367f032d93F642f64180aa3'))
"

  # Check integer formatting
  assert_output --partial "Integer result:"
  assert_output --partial "42"

  # Check boolean formatting
  assert_output --partial "Boolean results:"
  # Can't check specific outputs since we don't have ABI info in this test

  # Check address formatting
  assert_output --partial "Address result:"
  assert_output --partial "0x5FbDB2315678afecb367f032d93F642f64180aa3"

  assert_success
}
