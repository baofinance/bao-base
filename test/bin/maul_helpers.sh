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
  cat >"$BATS_TEST_TMPDIR/out/${contract_name}.json" <<EOF
{
  "abi": $content
}
EOF
}

# Finds a free port that can be used for testing
# Deliberately starts from a non-standard port to avoid conflicts with manual testing
find_free_port() {
  # Start from port 9000 range to avoid conflict with default anvil port 8545
  local start_port=${1:-9000}
  local max_attempts=${2:-100}
  local port=$start_port

  # Skip the default anvil port if we happen to check it
  if [ "$port" -eq 8545 ]; then
    port=$((port + 1))
  fi

  for i in $(seq 1 $max_attempts); do
    # Skip any ports too close to the default anvil port
    if [ "$port" -ge 8540 ] && [ "$port" -le 8550 ]; then
      port=8551
      continue
    fi

    if ! nc -z localhost $port &>/dev/null; then
      echo "Selected free port $port (avoiding Anvil default port)" >&3
      echo $port
      return 0
    fi
    port=$((port + 1))
  done

  echo "Could not find a free port after $max_attempts attempts" >&2
  return 1
}

# Starts anvil with a unique identifier for this test
start_anvil() {
  local chain_id=${1:-1337}
  local network=${2:-mainnet}
  local test_id=${3:-$(date +%s)-$$}

  # Find a free port
  local port=$(find_free_port)
  echo "Using port $port for anvil" >&3

  # Create a unique data directory for this instance
  local anvil_dir=$(mktemp -d)
  export ANVIL_DATA_DIR="$anvil_dir"
  export ANVIL_TEST_ID="$test_id"
  export ANVIL_PORT="$port"
  export ANVIL_RPC_URL="http://localhost:$port"

  echo "RPC URL: $ANVIL_RPC_URL" >&3

  # Clear the log file if it exists
  rm -f "/tmp/anvil-$test_id.log"

  # Set explicit RPC URL in environment for forwarding to maul commands
  export ANVIL_RPC_URL="http://localhost:$port"
  echo "RPC URL: $ANVIL_RPC_URL" >&3

  maul start --chain-id "$chain_id" --port "$port" >"/tmp/anvil-$test_id.log" 2>&1 &
  export MAUL_PID=$!
  echo "Started maul with PID $MAUL_PID" >&3

  # Wait for anvil to be ready
  local timeout=50 # 5 seconds
  local success=false

  # First wait for port to open
  echo "Waiting for port $port to open..." >&3
  for i in $(seq 1 $timeout); do
    if nc -z localhost "$port" &>/dev/null; then
      echo "Port $port is now open" >&3
      break
    fi
    sleep 0.1

    # Check if process died
    if ! ps -p $MAUL_PID &>/dev/null; then
      echo "Maul process died unexpectedly" >&3
      cat "/tmp/anvil-$test_id.log" >&3
      return 1
    fi
  done

  # Check if port opened successfully
  if ! nc -z localhost "$port" &>/dev/null; then
    echo "Timed out waiting for port to open" >&3
    cat "/tmp/anvil-$test_id.log" >&3
    stop_anvil
    return 1
  fi

  # Then wait for "Anvil is ready" message
  echo "Waiting for 'Anvil is ready' message..." >&3
  for i in $( # 10 seconds
    seq 1 100
  ); do
    if grep -q "Anvil is ready" "/tmp/anvil-$test_id.log" &>/dev/null; then
      echo "Found 'Anvil is ready' message" >&3
      success=true
      break
    fi
    sleep 0.1
  done

  # Find the anvil PID (child of maul process)
  export ANVIL_PID=$(pgrep -P $MAUL_PID 2>/dev/null | head -1)
  if [ -z "$ANVIL_PID" ]; then
    # Fallback - look for anvil with the port we specified
    export ANVIL_PID=$(pgrep -f "anvil.*--port $port" 2>/dev/null | head -1)
  fi

  echo "Anvil PID: $ANVIL_PID" >&3

  if [ "$success" = true ] && [ -n "$ANVIL_PID" ]; then
    echo "Anvil started successfully at $ANVIL_RPC_URL" >&3
    return 0
  else
    echo "Failed to start anvil (PID: $ANVIL_PID, Port: $port)" >&3
    cat "/tmp/anvil-$test_id.log" >&3
    stop_anvil
    return 1
  fi
}

# Safely stops anvil instance started by start_anvil
stop_anvil() {
  echo "Stopping anvil (MAUL_PID: $MAUL_PID, ANVIL_PID: $ANVIL_PID)" >&3

  # Only kill processes that we know belong to our test
  if [ -n "$MAUL_PID" ] && ps -p $MAUL_PID &>/dev/null; then
    echo "Killing maul process $MAUL_PID" >&3
    kill $MAUL_PID 2>/dev/null || true
  fi

  if [ -n "$ANVIL_PID" ] && ps -p $ANVIL_PID &>/dev/null; then
    echo "Killing anvil process $ANVIL_PID" >&3
    kill $ANVIL_PID 2>/dev/null || true

    # Wait briefly for process to terminate
    for i in {1..5}; do
      if ! ps -p $ANVIL_PID &>/dev/null; then
        echo "Anvil process $ANVIL_PID terminated" >&3
        break
      fi
      sleep 0.2
    done

    # Force kill if still running
    if ps -p $ANVIL_PID &>/dev/null; then
      echo "Force killing anvil process $ANVIL_PID" >&3
      kill -9 $ANVIL_PID 2>/dev/null || true
    fi
  fi

  # Look for any leftover anvil processes with our port
  if [ -n "$ANVIL_PORT" ]; then
    local leftover=$(pgrep -f "anvil.*--port $ANVIL_PORT" 2>/dev/null)
    if [ -n "$leftover" ]; then
      echo "Found leftover anvil processes for port $ANVIL_PORT: $leftover" >&3
      echo "Force killing leftover processes" >&3
      kill -9 $leftover 2>/dev/null || true
    fi
  fi

  # Clean up data directory
  if [ -n "$ANVIL_DATA_DIR" ] && [ -d "$ANVIL_DATA_DIR" ]; then
    rm -rf "$ANVIL_DATA_DIR"
  fi

  echo "Cleanup complete" >&3

  # Reset variables to prevent accidental reuse
  MAUL_PID=""
  ANVIL_PID=""
  ANVIL_DATA_DIR=""
  ANVIL_TEST_ID=""
  ANVIL_PORT=""
}
