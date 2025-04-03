#!/usr/bin/env bats

load "bats_helpers.sh"

# Setup function runs before each test
# setup() {
#   # Save original directory and move to project root
#   ORIG_DIR="$PWD"
#   cd "$BATS_TEST_DIRNAME/../.." || fail "Could not cd to project root"
# }

# # Teardown function runs after each test
# teardown() {
#   # Return to original directory
#   cd "$ORIG_DIR" || true
# }

# Test running the nothing script
@test "run should execute nothing script correctly" {
    run ./run nothing
    expect --head "Running as bash: ./bin/nothing"
    expect --tail "0 arguments: "
}

@test "run should execute nothing script with parameters correctly" {
    run ./run nothing hello world
    expect --head "Running as bash: ./bin/nothing hello world"
    expect --tail "2 arguments: hello world"
}

# Test running the nothing-python script
@test "run should execute nothing-python script correctly" {
  run ./run nothing-python
  expect --head "Running as python: ./bin/nothing-python.py"
  expect --tail "nothing arguments: []"
}

@test "run should execute nothing-python script with parameters correctly" {
  run ./run nothing-python blah
  expect --head "Running as python: ./bin/nothing-python.py blah"
  expect --tail "nothing arguments: ['blah']"
}

# Test running nothing-dir/run.sh
@test "run should execute nothing-dir/run.sh correctly" {
  run ./run nothing-dir
  expect --head "Running: ./bin/nothing-dir/run.sh"
  expect --tail "0 arguments: "
}

# Test passing arguments to nothing-dir script
@test "run should pass arguments correctly to nothing-dir script" {
  run ./run nothing-dir arg1 arg2
  expect --head "Running: ./bin/nothing-dir/run.sh arg1 arg2"
  expect --tail "2 arguments: arg1 arg2"
}

# Test running non-existent script
@test "run should fail gracefully with non-existent target" {
  run ./run non-existent-target
  expect --status 1 "ERROR: unknown file type for target: non-existent-target"
}
