#!/usr/bin/env bats

# setup() {
#    needs to be no sourcing of logging here or the startup tests fail
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
@test "logging levels work" {

    source lib/bao-base/bin/modules/logging
    logging_config warn

    run logging debug "debug should be hidden"
    run logging info " info should be hidden"
    run logging warn "warn ok"
    run logging error "error ok"

    logging debug "debug should be hidden"
    logging info " info should be hidden"
    logging warn "warn ok"
    logging error "error ok"

    # [ '1' == '0' ] # uncomment this and check the output
}
