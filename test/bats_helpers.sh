#!/usr/bin/env bash
# Helper functions for BATS tests

bbrun() {
    run ./run -q "$@"
}

expect() {
    local expected_status=0
    local mode="exact"
    local selected_output="$output"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --head)
                selected_output=$(echo "$selected_output" | head -n 1)
                shift ;;
            --tail)
                selected_output=$(echo "$selected_output" | tail -n 1)
                shift ;;
            --partial)
                mode="partial"
                shift ;;
            --regexp)
                mode="regexp"
                shift ;;
            *)  break ;;
        esac
    done

    local expected
    if [ "$#" -eq 0 ]; then
        expected=$(cat)
    else
        expected="$1"
    fi

    echo "status=$status, expected=$expected_status"
    echo "output=$selected_output."
    echo "expect=$expected."

    [ "$status" -eq "$expected_status" ] || return 1
    case "$mode" in
        exact)
            [[ "$selected_output" == "$expected" ]] || return 1
            ;;
        partial)
            [[ "$selected_output" =~ "$expected" ]] || return 1
            ;;
        regexp)
            [[ "$selected_output" =~ $expected ]] || return 1
            ;;
    esac
    return 0
}

# Debug helper to print information during test execution
# Usage: debug "message"
debug() {
  echo "# $*" >&3
}
