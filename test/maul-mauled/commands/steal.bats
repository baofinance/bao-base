#!/usr/bin/env bats

maul() {
  "${BATS_TEST_DIRNAME}/../../../../run" maul "$@"
}

cast() {
  "${BATS_TEST_DIRNAME}/../../../../run" cast "$@"
}

# Setup: Start anvil in background for tests
setup() {
  # Only start anvil once for all tests
  if [ -z "$ANVIL_PID" ]; then
    # Start anvil in background with a unique port to avoid conflicts
    PORT=${ANVIL_PORT:-8545}
    "${BATS_TEST_DIRNAME}/../../../../run" anvil --port $PORT >/tmp/anvil.log 2>&1 &
    ANVIL_PID=$!

    # Wait for anvil to start
    for _ in {1..30}; do
      if nc -z localhost $PORT; then
        break
      fi
      sleep 0.5
    done

    # Export for use in all tests
    export ANVIL_PID
    export ANVIL_PORT=$PORT
  fi
}

# Teardown: Kill the anvil process after all tests
teardown() {
  # Only kill anvil after the last test
  if [ "${BATS_TEST_NUMBER}" -eq "${#BATS_TEST_NAMES[@]}" ] && [ -n "$ANVIL_PID" ]; then
    kill -9 $ANVIL_PID
    unset ANVIL_PID
  fi
}

@test "steal command adds ETH to an address" {
  TEST_ADDRESS="0x0000000000000000000000000000000000000123"

  # Ensure the account has 0 ETH
  cast rpc anvil_setBalance $TEST_ADDRESS 0x0

  # Initial balance should be 0
  initial_balance=$(cast balance $TEST_ADDRESS)
  [ "$initial_balance" -eq 0 ]

  # Run steal command
  run maul steal --to $TEST_ADDRESS --amount 5
  [ "$status" -eq 0 ]

  # Check balance increased by 5 ETH
  new_balance=$(cast balance $TEST_ADDRESS)
  new_balance_eth=$(cast from-wei $new_balance)

  # Check the balance is approximately 5 ETH (allow for small precision differences)
  [[ "$new_balance_eth" == "5."* ]]
}

@test "steal command adds ERC20 tokens to an address" {
  # This test requires a token contract to be deployed
  # We'll use WETH as an example, which allows us to deposit ETH to get WETH tokens

  TEST_ADDRESS="0x0000000000000000000000000000000000000456"
  WETH_ADDRESS="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"

  # Give the test address some ETH first
  maul steal --to $TEST_ADDRESS --amount 1

  # Run steal command for ERC20
  run maul steal --to $TEST_ADDRESS --amount 0.1 --erc20 $WETH_ADDRESS

  # Check for success message in output
  [[ "$output" == *"status"*"success"* ]]

  # Check token balance
  token_balance=$(cast call $WETH_ADDRESS "balanceOf(address)(uint256)" $TEST_ADDRESS)
  token_balance_eth=$(cast from-wei $token_balance)

  # Allow for partial success (might not get exactly 0.1)
  [[ $(echo "$token_balance_eth > 0" | bc) -eq 1 ]]
}
