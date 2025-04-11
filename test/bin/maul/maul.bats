#!/usr/bin/env bats

# Helper to run maul commands
maul() {
  "${BATS_TEST_DIRNAME}/../../../run" maul "$@"
}

# Setup: Start anvil in background for tests
setup() {
  # Only start anvil once for all tests
  if [ -z "$ANVIL_PID" ]; then
    # Start anvil in background with a unique port to avoid conflicts
    PORT=${ANVIL_PORT:-8545}
    "${BATS_TEST_DIRNAME}/../../../run" anvil --port $PORT >/tmp/anvil.log 2>&1 &
    ANVIL_PID=$!

    # Wait for anvil to start
    for _ in {1..30}; do
      if nc -z localhost $PORT; then
        break
      fi
      sleep 0.5
    done

    # Verify anvil is running
    if ! nc -z localhost $PORT; then
      echo "Error: anvil failed to start" >&2
      cat /tmp/anvil.log
      exit 1
    fi

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

@test "maul command shows help when run without arguments" {
  run maul
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: maul"* ]]
}

@test "maul start command can be run with --help" {
  run maul start --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--chain-id"* ]]
}

@test "maul steal command can add ETH to an address" {
  # Get initial balance
  initial_balance=$(${BATS_TEST_DIRNAME}/../../../run cast balance 0x1234567890123456789012345678901234567890)

  # Run steal command
  run maul steal --to 0x1234567890123456789012345678901234567890 --amount 10
  [ "$status" -eq 0 ]

  # Get new balance
  new_balance=$(${BATS_TEST_DIRNAME}/../../../run cast balance 0x1234567890123456789012345678901234567890)

  # Convert wei to ETH for comparison
  initial_eth=$(${BATS_TEST_DIRNAME}/../../../run cast from-wei $initial_balance)
  new_eth=$(${BATS_TEST_DIRNAME}/../../../run cast from-wei $new_balance)

  # Check balance increased by ~10 ETH (allow for small precision differences)
  difference=$(echo "$new_eth - $initial_eth" | bc)
  [[ $(echo "$difference >= 9.99" | bc) -eq 1 ]]
  [[ $(echo "$difference <= 10.01" | bc) -eq 1 ]]
}

@test "maul call command can read state from a contract" {
  # Use a known contract like WETH on mainnet
  # WETH address on mainnet
  WETH_ADDRESS="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"

  # Call name() function
  run maul call --to $WETH_ADDRESS --sig "name()(string)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wrapped Ether"* ]]
}

@test "maul sig command provides function information" {
  run maul sig ERC20.transfer
  [ "$status" -eq 0 ]
  [[ "$output" == *"transfer(address,uint256)"* ]]
  [[ "$output" == *"Input Parameters"* ]]
}
