#!/usr/bin/env bats

load "common.bash"

@test "sig: should show function signature from contract" {
  # Mock necessary commands
  # Handled by common.bash creating test ABIs

  # Run the command
  run python "$MAUL_PATH" sig ERC20.transfer

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains '*** signature for ERC20.transfer is "transfer(address,uint256)"'
  assert_output_contains "Input Parameters:"
  assert_output_contains "recipient: address"
  assert_output_contains "amount: uint256"
}

@test "sig: should show return values" {
  # Mock necessary commands
  # Handled by common.bash creating test ABIs

  # Run the command
  run python "$MAUL_PATH" sig ERC20.balanceOf

  # Assert command execution was successful
  [ "$status" -eq 0 ]

  # Assert output contains expected messages
  assert_output_contains '*** signature for ERC20.balanceOf is "balanceOf(address)"'
  assert_output_contains "Input Parameters:"
  assert_output_contains "account: address"
  assert_output_contains "Return Values:"
  assert_output_contains "return_0: uint256"
}

@test "sig: should error on invalid signature format" {
  # Run the command with incorrect signature format
  run python "$MAUL_PATH" sig invalidFormat

  # Assert command failed
  [ "$status" -eq 1 ]

  # Assert output contains expected error message
  assert_output_contains "*** error: When using a raw function signature, you must use the Contract.function format"
}
