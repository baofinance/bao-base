#!/usr/bin/env bats

load "common.bash"

@test "send: should execute state-changing function call" {
  # Mock necessary commands
  cat >"$BATS_TMPDIR/mock_cast" <<EOF
#!/bin/bash
if [[ \$* == *"send"* && \$* == *"transfer"* ]]; then
  echo "Transaction hash: 0x1234"
else
  echo "Success"
fi
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_cast"
  export PATH="$BATS_TMPDIR:$PATH"

  # Run the command
  run python "$MAUL_PATH" send --to "0xToken" --sig "ERC20.transfer" "0xRecipient" "1000000000000000000"

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains "*** send to 0xToken with signature transfer(address,uint256)"
  assert_output_contains "Transaction hash: 0x1234"
}

@test "send: should execute with impersonation" {
  # Mock necessary commands
  cat >"$BATS_TMPDIR/mock_cast" <<EOF
#!/bin/bash
if [[ \$* == *"rpc"* && \$* == *"impersonate"* ]]; then
  echo "Impersonating account"
elif [[ \$* == *"send"* && \$* == *"transfer"* ]]; then
  echo "Transaction hash: 0x1234"
else
  echo "Success"
fi
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_cast"
  export PATH="$BATS_TMPDIR:$PATH"

  # Run the command
  run python "$MAUL_PATH" send --to "0xToken" --sig "ERC20.transfer" "0xRecipient" "1000000000000000000" --as "0xAdmin"

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains "*** send to 0xToken with signature transfer(address,uint256) as 0xAdmin"
  assert_output_contains "Transaction hash: 0x1234"
}

@test "send: should handle private key authentication" {
  # Mock necessary commands
  cat >"$BATS_TMPDIR/mock_cast" <<EOF
#!/bin/bash
if [[ \$* == *"wallet"* ]]; then
  echo "0xMyAddress"
elif [[ \$* == *"send"* && \$* == *"--private-key"* ]]; then
  echo "Transaction hash: 0x1234"
else
  echo "Success"
fi
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_cast"
  export PATH="$BATS_TMPDIR:$PATH"

  # Run the command
  run python "$MAUL_PATH" send --to "0xToken" --sig "ERC20.transfer" "0xRecipient" "1000000000000000000"

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains "*** send to 0xToken with signature transfer(address,uint256)"
  assert_output_contains "Transaction hash: 0x1234"
}
