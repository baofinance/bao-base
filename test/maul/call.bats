#!/usr/bin/env bats

load "common.bash"

@test "call: should execute read-only function call" {
  # Mock necessary commands
  cat >"$BATS_TMPDIR/mock_cast" <<EOF
#!/bin/bash
if [[ \$* == *"call"* && \$* == *"balanceOf"* ]]; then
  echo "1000000000000000000" # 1 ETH in wei
else
  echo "Success"
fi
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_cast"
  export PATH="$BATS_TMPDIR:$PATH"

  # Run the command
  run python "$MAUL_PATH" call --to "0xToken" --sig "ERC20.balanceOf" "0xUser"

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains "*** call to 0xToken with signature balanceOf(address)"
  assert_output_contains "Result: 1000000000000000000"
}

@test "call: should execute with raw signature" {
  # Mock necessary commands
  cat >"$BATS_TMPDIR/mock_cast" <<EOF
#!/bin/bash
if [[ \$* == *"call"* && \$* == *"balanceOf"* ]]; then
  echo "1000000000000000000" # 1 ETH in wei
else
  echo "Success"
fi
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_cast"
  export PATH="$BATS_TMPDIR:$PATH"

  # Run the command
  run python "$MAUL_PATH" call --to "0xToken" --sig "balanceOf(address)" "0xUser"

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains "*** call to 0xToken with signature balanceOf(address)"
  assert_output_contains "Result: 1000000000000000000"
}

@test "call: should handle impersonation" {
  # Mock necessary commands
  cat >"$BATS_TMPDIR/mock_cast" <<EOF
#!/bin/bash
if [[ \$* == *"rpc"* && \$* == *"impersonate"* ]]; then
  echo "Impersonating account"
elif [[ \$* == *"call"* && \$* == *"balanceOf"* ]]; then
  echo "1000000000000000000" # 1 ETH in wei
else
  echo "Success"
fi
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_cast"
  export PATH="$BATS_TMPDIR:$PATH"

  # Run the command
  run python "$MAUL_PATH" call --to "0xToken" --sig "ERC20.balanceOf" "0xUser" --as "0xAdmin"

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains "*** call to 0xToken with signature balanceOf(address) as 0xAdmin"
}
