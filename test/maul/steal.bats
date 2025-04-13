#!/usr/bin/env bats

load "common.bash"

@test "steal: should transfer ETH to address" {
  # Mock necessary commands
  mock_cast_balance
  mock_cast_to_wei
  mock_cast_from_wei
  mock_cast_rpc

  # Run the command
  run python "$MAUL_PATH" steal --to "0xUser" --amount "1"

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains "*** transfer 0xUser 1 ETH"
  assert_output_contains "balance is now 1.0"
}

@test "steal: should transfer ETH to named wallet" {
  # Mock necessary commands
  mock_cast_balance
  mock_cast_to_wei
  mock_cast_from_wei
  mock_cast_rpc

  # Run the command
  run python "$MAUL_PATH" steal --to "testwallet" --amount "1"

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains "*** transfer testwallet 1 ETH"
  assert_output_contains "balance is now 1.0"
}

@test "steal: should transfer ERC20 tokens" {
  # Mock commands
  mock_cast_to_wei
  mock_cast_from_wei

  # Create a more complex mock for cast call to handle the logs request
  cat >"$BATS_TMPDIR/mock_cast" <<EOF
#!/bin/bash
if [[ \$* == *"balanceOf"* ]]; then
  echo "1000000000000000000"  # 1 ETH in wei
elif [[ \$* == *"logs"* ]]; then
  echo '[{"topics":["0xTransfer", "0xFromAddr", "0x000000000000000000000000a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4"]}]'
elif [[ \$* == *"block"* ]]; then
  echo "1000000"
else
  echo "Success"
fi
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_cast"
  export PATH="$BATS_TMPDIR:$PATH"

  # Run the command
  run python "$MAUL_PATH" steal --to "0xUser" --amount "1" --erc20 "wsteth"

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains "*** transfer 0xUser 1 ERC20 wsteth"
}

@test "steal: should handle alias commands" {
  # Mock necessary commands
  mock_cast_balance
  mock_cast_to_wei
  mock_cast_from_wei
  mock_cast_rpc

  # Run the command with an alias
  run python "$MAUL_PATH" grab --to "0xUser" --amount "1"

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains "*** transfer 0xUser 1 ETH"
  assert_output_contains "balance is now 1.0"
}
