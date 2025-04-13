#!/usr/bin/env bats

load "common.bash"

@test "start: should launch anvil instance" {
  # We need to mock more complex behavior here
  # Create a more comprehensive mock script for this test
  cat >"$BATS_TMPDIR/mock_anvil" <<EOF
#!/bin/bash
echo "Listening on 127.0.0.1:8545"
# Keep running for a bit before exiting
sleep 2
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_anvil"

  cat >"$BATS_TMPDIR/mock_cast" <<EOF
#!/bin/bash
echo "Success"
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_cast"

  cat >"$BATS_TMPDIR/mock_nc" <<EOF
#!/bin/bash
# Simulate port check success after brief wait
sleep 1
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_nc"

  export PATH="$BATS_TMPDIR:$PATH"

  # Run with timeout to avoid hanging
  run timeout 3s python "$MAUL_PATH" start -f mainnet

  # In this case we expect non-zero status because we killed it with timeout
  [ "$status" -ne 0 ]

  # But we should still see the startup messages
  assert_output_contains ">>> anvil -f mainnet"
}

@test "start: should support custom chain-id" {
  # Create mock scripts
  cat >"$BATS_TMPDIR/mock_anvil" <<EOF
#!/bin/bash
echo "Listening on 127.0.0.1:8545 with chain ID 1337"
# Keep running for a bit before exiting
sleep 2
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_anvil"

  cat >"$BATS_TMPDIR/mock_cast" <<EOF
#!/bin/bash
echo "Success"
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_cast"

  cat >"$BATS_TMPDIR/mock_nc" <<EOF
#!/bin/bash
# Simulate port check success after brief wait
sleep 1
exit 0
EOF
  chmod +x "$BATS_TMPDIR/mock_nc"

  export PATH="$BATS_TMPDIR:$PATH"

  # Run with timeout to avoid hanging
  run timeout 3s python "$MAUL_PATH" start -f mainnet --chain-id 1337

  # In this case we expect non-zero status because we killed it with timeout
  [ "$status" -ne 0 ]

  # But we should still see the startup messages with chain-id
  assert_output_contains ">>> anvil -f mainnet --chain-id 1337"
}
