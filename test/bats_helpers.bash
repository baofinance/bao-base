#!/usr/bin/env bash
# Helper functions for BATS tests

expect() {
    local expected_status=0
    local cut_output="$output"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --head)
                local cut_output=$(echo "$cut_output" | head -n 1)
                shift
                ;;
            --tail)
                local cut_output=$(echo "$cut_output" | tail -n 1)
                shift
                ;;
            --status)
                expected_status="$2"
                shift 2
                ;;
            *) break ;;
        esac
    done

    echo "status=$status, expected=$expected_status"
    [ "$status" -eq "$expected_status" ] || return 1

    local expected="$1"
    echo "output=$cut_output."
    echo "expect=$expected."
    [ "$cut_output" == "$expected" ] || return 1

    return 0
}

# Check exit status with optional expected value
# Usage: assert_status [--status N]
# Default expected status is 0
assert_status() {
  local expected=0

  if [[ "$1" == "--status" ]]; then
    shift
    expected="$1"
    shift
  fi

  if [[ "$status" -ne "$expected" ]]; then
    echo "Expected status: $expected, actual: $status"
    echo "Output: $output"
    return 1
  fi

  return 0
}

# Check if output matches exactly what's expected
# Usage: assert_output_equals "expected output"
assert_output_equals() {
  local expected="$1"

  if [[ "$output" != "$expected" ]]; then
    echo "Output doesn't match expected value"
    echo "Expected: $expected"
    echo "Actual: $output"
    return 1
  fi

  return 0
}

# Check if output contains a string
# Usage: assert_output_contains "substring"
assert_output_contains() {
  local expected="$1"

  if [[ "$output" != *"$expected"* ]]; then
    echo "Output doesn't contain expected substring"
    echo "Expected to contain: $expected"
    echo "Actual output: $output"
    return 1
  fi

  return 0
}

# Debug helper to print information during test execution
# Usage: debug "message"
debug() {
  echo "# $*" >&3
}
