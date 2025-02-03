#!/usr/bin/env bats

# setup() {
# }

@test "setup can detect fd is not in use" {
    run lib/bao-base/bin/modules/logging
    echo "status=$status"
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '' ]
}

@test "setup can detect fd is in use" {
    exec 8>/dev/null
    run source lib/bao-base/bin/modules/logging
    echo "status=$status"
    [ "$status" -eq 1 ]
    echo "output=$output"
    [[ "$output" == *FAIL* ]]
}

# TODO: test logging levels work
