#!/usr/bin/env bats

load "common.bash"

@test "grant: should grant role to address" {
  # Mock necessary commands
  cat >"$BATS_TMPDIR/mock_cast" <<EOF
#!/bin/bash
if [[ \$* == *"call"* && \$* == *"MINTER_ROLE"* ]]; then
  echo "1" # Role ID
elif [[ \$* == *"send"* ]]; then
  echo "Transaction hash: 0x1234"
else
  echo "Success"
fi
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_cast"
  export PATH="$BATS_TMPDIR:$PATH"

  # Run the command
  run python "$MAUL_PATH" grant --role "MINTER_ROLE" --on "MockToken" --to "0xUser"

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains "*** grant role MINTER_ROLE on MockToken to 0xUser"
}

@test "grant: should grant role with impersonation" {
  # Mock necessary commands
  cat >"$BATS_TMPDIR/mock_cast" <<EOF
#!/bin/bash
if [[ \$* == *"call"* && \$* == *"MINTER_ROLE"* ]]; then
  echo "1" # Role ID
elif [[ \$* == *"send"* ]]; then
  echo "Transaction hash: 0x1234"
else
  echo "Success"
fi
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_cast"
  export PATH="$BATS_TMPDIR:$PATH"

  # Run the command
  run python "$MAUL_PATH" grant --role "MINTER_ROLE" --on "MockToken" --to "0xUser" --as "0xAdmin"

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains "*** grant role MINTER_ROLE on MockToken to 0xUser as 0xAdmin"
}
