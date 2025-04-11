#!/usr/bin/env bats

# Load the helper functions
load "../../maul_helpers.sh"

maul() {
  "${BATS_TEST_DIRNAME}/../../../../run" maul "$@"
}

setup() {
  # Ensure ETH_RPC_URL is unset to prevent interference with tests
  unset ETH_RPC_URL

  # Generate a unique test ID
  export TEST_ID="test-$(date +%s)-$$"

  # Set up a timeout trap to prevent hanging
  export TEST_STARTED_AT=$(date +%s)
}

teardown() {
  # Safely stop anvil with the helper function
  echo "Running teardown cleanup" >&3
  stop_anvil
  echo "Teardown complete" >&3

  # Make sure we don't have hanging anvil processes
  pkill -f "anvil -f mainnet --chain-id 1337" || true
}

# This function will be called automatically before the test runs
# and will force exit if the test runs longer than the timeout
check_timeout() {
  local timeout=$1
  local current_time=$(date +%s)
  local elapsed=$((current_time - TEST_STARTED_AT))

  if [ $elapsed -gt $timeout ]; then
    echo "Test timed out after $elapsed seconds - forcing exit" >&3
    echo "--- Current processes ---" >&3
    ps aux | grep anvil >&3
    exit 1
  fi
}

@test "start command launches anvil process" {
  # Set a timeout to force test completion after 20 seconds
  trap 'check_timeout 20' DEBUG

  echo "Starting test" >&3

  # Start anvil with helper function
  if ! start_anvil 1337 mainnet "$TEST_ID"; then
    echo "Failed to start anvil - test cannot continue" >&3
    return 1
  fi

  echo "Anvil started successfully" >&3

  # Verify we have valid PIDs and port
  [ -n "$MAUL_PID" ]
  [ -n "$ANVIL_PID" ]
  [ -n "$ANVIL_PORT" ]

  # Display log for debugging
  echo "--- Anvil Log Output ---" >&3
  cat "/tmp/anvil-$TEST_ID.log" >&3
  echo "----------------------" >&3

  # Verify anvil is running by checking the port is open
  nc -z localhost "$ANVIL_PORT"

  # Use sleep with timeout to prevent hanging - max 5 seconds
  echo "Test completed successfully, cleaning up" >&3
}
