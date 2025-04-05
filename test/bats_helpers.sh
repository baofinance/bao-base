#!/usr/bin/env bash
# Helper functions for BATS tests

bbrun() {
    run ./run -q "$@"
}

# usage:
# expect [--success|--failure] [--head|--tail] [--partial|--regexp|--regex] [--not] <expected>
expect() {
    local status_result
    local mode="exact"
    local selected_output="$output"
    local success=0
    local fail=1
    local logic=""
    # Parse arguments
    set -- "--success" "$@" # default to success
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status)
                if [[ "$status" -eq "$2" ]]; then
                    status_result=1
                else
                    status_result=0
                fi
                expected_status=" = $2"
                shift 2
                ;;
            --failure)
                if [[ "$status" -eq 0 ]]; then
                    status_result=1
                else
                    status_result=0
                fi
                expected_status=" ! =0"
                shift
                ;;
            --success)
                if [ "$status" -eq 0 ]; then
                    status_result=0
                else
                    status_result=1
                fi
                expected_status="=0"
                shift
                ;;
            --head)
                selected_output=$(echo "$selected_output" | head -n 1)
                shift
                ;;
            --tail)
                selected_output=$(echo "$selected_output" | tail -n 1)
                shift
                ;;
            --partial)
                mode="partial"
                shift
                ;;
            --regexp | --regex)
                mode="regexp"
                shift
                ;;
            --not)
                logic="not "
                success=1
                fail=0
                shift
                ;;
            *) break ;;
        esac
    done

    local expected
    if [ "$#" -eq 0 ]; then
        expected=$(cat)
    else
        expected="$1"
    fi

    echo "BATS \$output:
$output
:"
    echo "status=$status expect$expected_status"
    echo "status_result=$status_result."
    echo "comparison=$logic$mode"
    echo "output=$selected_output."
    echo "expect=$expected."
    echo "---"

    [ "$status_result" -eq 0 ] || return 1

    case "$mode" in
        exact)
            [[ "$selected_output" == "$expected" ]] || return $fail
            ;;
        partial)
            [[ "$selected_output" =~ "$expected" ]] || return $fail
            ;;
        regexp)
            [[ "$selected_output" =~ $expected ]] || return $fail
            ;;
    esac
    return $success
}

expect_success() {
    expect_output --status 0 "$@"
}

expect_failure() {
    expect_output --status 1 "$@"
}

# # Debug helper to print information during test execution
# # Usage: debug "message"
# debug() {
#     echo "# $*" >&3
# }

run_python() {
    local python_code="$1"
    local bin_dir=$(echo "$BATS_TEST_DIRNAME" | sed 's#\(.*\)/test/#\1/#') # take out the test dir
    run bash -c "cd $bin_dir/.. && python3 -c \"$python_code\""
}
