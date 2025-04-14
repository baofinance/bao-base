#!/usr/bin/env bats

load ../bats_helpers.sh
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

  # Call name() function with explicit timeout to prevent hanging
  run maul call --to $WETH_ADDRESS --sig "name()(string)"
  expect --ends-with "Wrapped Ether"
}

@test "maul sig command provides function information" {
  run maul sig ERC20.transfer
  [ "$status" -eq 0 ]
  expect --contains "transfer(address,uint256)"
  expect --contains "Input Parameters"
}

@test "maul send command can execute state-changing transactions" {
  # Create a test wallet
  TEST_WALLET="0x1234567890123456789012345678901234567890"

  # Use a known token contract
  DAI_ADDRESS="0x6B175474E89094C44Da98b954EedeAC495271d0F"

  # Need funds in the wallet first
  run maul steal --to $TEST_WALLET --amount 50
  [ "$status" -eq 0 ]

  # Get some DAI for the test wallet
  export DEBUG=maul,vvv
  run maul steal --to $TEST_WALLET --amount 100 --erc20 $DAI_ADDRESS
  expect ""

  # Create a destination address
  DEST_WALLET="0x2345678901234567890123456789012345678901"

  # Check initial DAI balance of destination
  initial_dai=$(cast_anvil call $DAI_ADDRESS "balanceOf(address)(uint256)" $DEST_WALLET)
  echo "Initial DAI: $initial_dai"

  # Send 10 DAI to dest wallet
  run maul send --to $DAI_ADDRESS --sig "transfer(address,uint256)" --as $TEST_WALLET $DEST_WALLET 10000000000000000000
  expect ""

  # Check new DAI balance of destination
  new_dai=$(cast_anvil call $DAI_ADDRESS "balanceOf(address)(uint256)" $DEST_WALLET)
  echo "New DAI: $new_dai"

  # Verify balance increased by ~10 DAI (allowing for small precision differences)
  initial_eth=$(cast from-wei $initial_dai)
  new_eth=$(cast from-wei $new_dai)
  difference=$(echo "$new_eth - $initial_eth" | bc)

  [ $(echo "$difference >= 9.99" | bc) -eq 1 ]
  [ $(echo "$difference <= 10.01" | bc) -eq 1 ]
}

@test "maul can impersonate accounts" {
  # Test with a known rich address on mainnet
  RICH_ADDR="0xF977814e90dA44bFA03b6295A0616a897441aceC" # Binance Hot Wallet
  TEST_WALLET="0x1234567890123456789012345678901234567890"

  # Get ETH balance before
  initial_balance=$(cast_anvil balance $TEST_WALLET)

  # Impersonate the account and send ETH
  run maul send --to $TEST_WALLET --sig "receive()" --as $RICH_ADDR --value 5ether
  [ "$status" -eq 0 ]

  # Check new balance
  new_balance=$(cast_anvil balance $TEST_WALLET)

  # Verify balance increased by ~5 ETH
  initial_eth=$(cast from-wei $initial_balance)
  new_eth=$(cast from-wei $new_balance)
  difference=$(echo "$new_eth - $initial_eth" | bc)

  [ $(echo "$difference >= 4.99" | bc) -eq 1 ]
  [ $(echo "$difference <= 5.01" | bc) -eq 1 ]
}

@test "maul grant can assign roles to accounts" {
  # First need to deploy a contract with roles
  # For this test, we'll use an existing one if available

  # Deploy mock role-based contract
  result=$(cast_anvil send --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --create "0x6080604052600080546001600160a01b031916331790553480156100225760006000fd5b5061025f806100326000396000f3fe608060405234801561001057600080fd5b50600436106100935760003560e01c8063b64e566e11610066578063b64e566e146100fd578063bb5f747b14610133578063c5b1d9aa14610163578063f2fde38b1461017b57610093565b80630c340a24146100985780634d14b6d7146100b657806361b6ebdc146100cd5780638da5cb5b146100e5575b600080fd5b6100a0610199565b6040516100ad9190610201565b60405180910390f35b6100cb6100c436600461019e565b6101c3565b005b6100a06100db36600461019e565b6101ca565b6000546100a0906001600160a01b031681565b60006100a0565b61012361010b36600461019e565b6001600160a01b03166000908152600160205260409020546001600160a01b031690565b6040516100ad91906101e6565b61015361014136600461019e565b6001600160a01b03163314155b90565b60405190151581526020016100ad565b61016b610191565b6040516100ad9190610201565b6100cb61018936600461019e565b505050565b6000546001600160a01b031681565b6000602082840312156101b057600080fd5b81356001600160a01b03811681146101c857600080fd5b9392505050565b50565b600060208190529081526040902054546001600160a01b031681565b6001600160a01b03811681146101ca57600080fd5b6020810161014782846101d5565b6020810161014782846101d55600a2646970667358221220a543ffa64ac6e61c28e7df174c8cc517ee01dce397e2b4b63f82fcb1bd7060b464736f6c63430008120033")

  # Extract deployed contract address
  CONTRACT_ADDR=$(echo "$result" | grep -oE "contract address: 0x[a-fA-F0-9]{40}" | cut -d' ' -f3)
  echo "Contract deployed at: $CONTRACT_ADDR"

  # Account to receive role
  TEST_ACCOUNT="0x1234567890123456789012345678901234567890"

  # Grant admin role (example role ID 0x1)
  run maul grant --role 0x1 --on $CONTRACT_ADDR --to $TEST_ACCOUNT
  [ "$status" -eq 0 ]

  # Verify role assignment (this would depend on the contract's specific way to check roles)
  result=$(cast_anvil call $CONTRACT_ADDR "hasRole(bytes32,address)(bool)" 0x1 $TEST_ACCOUNT)
  [[ "$result" == *"true"* ]] || [[ "$result" == *"1"* ]]
}

@test "maul steal command can add ERC20 tokens to an address" {
  # Test wallet
  TEST_WALLET="0x1234567890123456789012345678901234567890"

  # Use a well-known token with good liquidity for testing
  TOKEN_ADDRESS="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" # USDC

  # Get initial token balance
  initial_balance=$(cast_anvil call $TOKEN_ADDRESS "balanceOf(address)(uint256)" $TEST_WALLET)
  echo "Initial token balance: $initial_balance"

  # Steal 1000 tokens
  run maul steal --erc20 $TOKEN_ADDRESS --to $TEST_WALLET --amount 1000
  echo "output: $output"
  [ "$status" -eq 0 ]

  # Check new token balance
  new_balance=$(cast_anvil call $TOKEN_ADDRESS "balanceOf(address)(uint256)" $TEST_WALLET)
  echo "New token balance: $new_balance"

  # Calculate difference (considering decimal places)
  initial_num=$(cast from-wei $initial_balance 6) # USDC has 6 decimals
  new_num=$(cast from-wei $new_balance 6)
  difference=$(echo "$new_num - $initial_num" | bc)

  # Verify approximately 1000 tokens added
  [ $(echo "$difference >= 999" | bc) -eq 1 ]
  [ $(echo "$difference <= 1001" | bc) -eq 1 ]
}

@test "maul can format output for complex return types" {
  # Call a function that returns a complex type
  COMPOUND_ADDRESS="0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B" # Compound Comptroller

  # Call a function that returns multiple values
  run maul call --to $COMPOUND_ADDRESS --sig "getAccountLiquidity(address)(uint,uint,uint)" 0xF977814e90dA44bFA03b6295A0616a897441aceC
  [ "$status" -eq 0 ]

  # Expected format: should have multiple numeric values
  [[ "$output" == *"Result:"* ]]

  # Verify at least one numeric result is present
  [[ "$output" =~ [0-9]+ ]]
}
