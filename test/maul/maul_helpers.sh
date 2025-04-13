#!/usr/bin/env bash
# Helper functions for BATS maul tests

maul() {
  if [ -n "$ANVIL_PORT" ]; then
    # If ANVIL_PORT is set, use it for local anvil
    # echo "DEBUG: maul --local $ANVIL_PORT $*" >&2
    "${BATS_TEST_DIRNAME}/../../run" -q maul --local="$ANVIL_PORT" "$@"
  else
    # Otherwise, run maul normally
    # echo "DEBUG: maul $*" >&2
    "${BATS_TEST_DIRNAME}/../../run" -q maul "$@"
  fi
}

# Run a command with the correct rpc url
cast_anvil() {
  local command="$1"
  shift

  # Handle RPC URL properly when ANVIL_PORT is set
  if [ -n "$ANVIL_PORT" ]; then
    # echo "DEBUG: cast $command --rpc-url http://localhost:$ANVIL_PORT $*" >&2
    cast "$command" --rpc-url "http://localhost:$ANVIL_PORT" "$@"
  else
    # echo "DEBUG: cast $command $*" >&2
    cast "$command" "$@"
  fi
}

# Impersonate and setup an account with ETH
setup_account() {
  local address=$1
  local eth_amount=${2:-1}

  # Impersonate the account
  cast_anvil rpc anvil_impersonateAccount "$address" >/dev/null

  # Convert ETH to wei and hex
  local wei_amount=$(cast to-wei "$eth_amount")
  local hex_amount=$(cast to-hex "$wei_amount")

  # Set balance
  cast_anvil rpc anvil_setBalance "$address" "$hex_amount" >/dev/null

  echo "Account $address now has $eth_amount ETH"
}
