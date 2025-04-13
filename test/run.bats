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
  expect --head --ends-with "Running as bash: ./bin/nothing"
  expect --tail "0 arguments: "
}

@test "run should execute nothing script with parameters correctly" {
  run ./run nothing hello world
  expect --head --ends-with "Running as bash: ./bin/nothing hello world"
  expect --tail "2 arguments: hello world"
}

# Test running the nothing.py script
@test "run should execute nothing.py script correctly" {
  run ./run nothing.py
  expect --head --ends-with "Running as python: ./bin/nothing.py"
  expect --tail "nothing arguments: []"
}

@test "run should execute nothing.py script with parameters correctly" {
  run ./run nothing.py blah
  expect --head --ends-with "Running as python: ./bin/nothing.py blah"
  expect --tail "nothing arguments: ['blah']"
}

# Test running nothing-dir/run.sh
@test "run should execute nothing-dir/run.sh correctly" {
  run ./run nothing-dir
  expect --head --ends-with "Running: ./bin/nothing-dir/run.sh"
  expect --tail "0 arguments: "
}

# Test passing arguments to nothing-dir script
@test "run should pass arguments correctly to nothing-dir script" {
  run ./run nothing-dir arg1 arg2
  expect --head --ends-with "Running: ./bin/nothing-dir/run.sh arg1 arg2"
  expect --tail "2 arguments: arg1 arg2"
}

# Test running non-existent script
@test "run should fail gracefully with non-existent target" {
  run ./run non-existent-target
  expect --failure --starts-with "ERROR"
  expect --failure --ends-with "Could not determine script type for non-existent-target"
}
