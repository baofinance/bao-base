#!/usr/bin/env bats

load ./maul_helpers.sh

# Setup: Start anvil in background for tests
setup() {
  # Only start anvil once for all tests
  if [ -z "$ANVIL_PID" ]; then
    export ANVIL_PORT
    # Find a free port to use (starting above 8545)
    for i in $(seq 8546 $((8546 + 1000))); do
      if ! nc -z localhost $i >/dev/null 2>&1; then
        echo "Found free port: $i"
        ANVIL_PORT=$i
        break
      fi
    done

    [[ -n "$ANVIL_PORT" ]] || {
      echo "ERROR: Could not find a free port between 8546 and $((8546 + 1000))" >&2
      exit 1
    }

    echo "Using port $ANVIL_PORT for anvil"

    # Start anvil in background with proper output redirection
    echo "Starting anvil on port $ANVIL_PORT"
    # Use a unique log file for easier debugging
    LOG_FILE="/tmp/anvil-$ANVIL_PORT.log"
    anvil -f mainnet --port "$ANVIL_PORT" >"$LOG_FILE" 2>&1 &
    export ANVIL_PID=$!

    # Wait for anvil to start
    echo "Waiting for anvil to start..."
    start_time=$(date +%s)
    while ! nc -z localhost $ANVIL_PORT; do
      sleep 0.5
      current_time=$(date +%s)
      elapsed_time=$((current_time - start_time))
      if [ $elapsed_time -gt 10 ]; then
        echo "Error: anvil failed to start within 10 seconds" >&2
        cat "$LOG_FILE"
        exit 1
      fi
    done

    echo "Anvil started successfully on $ANVIL_PORT (PID: $ANVIL_PID)"
  fi
}

# Teardown: Kill the anvil process after tests - ALWAYS do this
teardown() {
  # Always clean up processes, regardless of test success or failure
  if [ -n "$ANVIL_PID" ]; then
    echo "Cleaning up anvil process (PID: $ANVIL_PID)..."

    # First try graceful termination
    kill -TERM $ANVIL_PID 2>/dev/null || true
    sleep 1

    # Check if process is still running
    if kill -0 $ANVIL_PID 2>/dev/null; then
      echo "Anvil process still running, sending SIGKILL"
      kill -KILL $ANVIL_PID 2>/dev/null || true
      sleep 1
    else
      echo "Anvil process terminated gracefully"
    fi

    # Also ensure port is freed
    if nc -z localhost $ANVIL_PORT >/dev/null 2>&1; then
      echo "Port $ANVIL_PORT still in use, attempting to kill processes using it"

      # Try to use lsof if available
      if command -v lsof >/dev/null 2>&1; then
        port_pids=$(lsof -ti:$ANVIL_PORT 2>/dev/null || echo "")
        if [ -n "$port_pids" ]; then
          echo "Killing processes using port $ANVIL_PORT: $port_pids"
          kill -9 $port_pids 2>/dev/null || true
        fi
      fi

      # Try to use fuser as a fallback
      if command -v fuser >/dev/null 2>&1; then
        fuser -k $ANVIL_PORT/tcp 2>/dev/null || true
      fi
    fi

    # Clean up environment variables
    unset ANVIL_PID
    unset ANVIL_PORT

    echo "Cleanup complete"
  fi
}

@test "maul steal command can add ETH to an address" {
  # Define test wallet
  TEST_WALLET="0x1234567890123456789012345678901234567890"

  # Get initial balance using the RPC URL
  initial_balance=$(cast_anvil balance $TEST_WALLET)
  echo "initial_balance: $initial_balance"

  # Run steal command with the RPC URL
  run maul steal --to $TEST_WALLET --amount 10
  echo "status: $status"
  echo "output: $output"
  [ "$status" -eq 0 ]

  # Get new balance
  new_balance=$(cast_anvil balance $TEST_WALLET)
  echo "new_balance: $new_balance"

  # Convert wei to ETH for comparison
  initial_eth=$(cast from-wei $initial_balance)
  new_eth=$(cast from-wei $new_balance)
  echo "initial_eth: $initial_eth"
  echo "new_eth: $new_eth"

  # Check balance increased by ~10 ETH (allow for small precision differences)
  difference=$(echo "$new_eth - $initial_eth" | bc)
  echo "difference: $difference"

  [[ $(echo "$difference >= 9.99" | bc) -eq 1 ]]
  [[ $(echo "$difference <= 10.01" | bc) -eq 1 ]]
}

@test "maul call command can read state from a contract" {
  # Use a known contract like WETH on mainnet
  WETH_ADDRESS="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"

  echo "Testing WETH contract at $WETH_ADDRESS via RPC URL http://localhost:$ANVIL_PORT"

  # Call name() function with explicit timeout to prevent hanging
  run maul call --to $WETH_ADDRESS --sig "name()(string)"

  # Print debugging information
  echo "Command status: $status"
  echo "Command output: $output"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Wrapped Ether"* ]]
}

@test "maul sig command provides function information" {
  run maul sig ERC20.transfer
  [ "$status" -eq 0 ]
  [[ "$output" == *"transfer(address,uint256)"* ]]
  [[ "$output" == *"Input Parameters"* ]]
}
