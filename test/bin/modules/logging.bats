#!/usr/bin/env bats

# setup() {
#    needs to be no sourcing of logging here or the startup tests fail
# }

@test "setup can detect fd is not in use" {
    run lib/bao-base/bin/modules/logging
    echo "status=$status"
    echo "output=$output"
    [ "$status" -eq 0 ]
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

    # need to set this for capturing the output
    _logging_file_descriptor=1

    logging_config debug
    run logging debug "debug message"
    echo "output=$output."
    [[ "$output" == *"debug message" ]]
    run logging info "info message"
    [[ "$output" == *"info message" ]]
    run logging warn "warn message"
    [[ "$output" == *"warn message" ]]
    run logging error "error message"
    [[ "$output" == *"error message" ]]

    logging_config info
    echo "output=$output."
    run logging debug "debug message"
    [[ "$output" == *"" ]]
    run logging info "info message"
    [[ "$output" == *"info message" ]]
    run logging warn "warn message"
    [[ "$output" == *"warn message" ]]
    run logging error "error message"
    [[ "$output" == *"error message" ]]

    logging_config warn
    echo "output=$output."
    run logging debug "debug message"
    [[ "$output" == *"" ]]
    run logging info "info message"
    [[ "$output" == *"" ]]
    run logging warn "warn message"
    [[ "$output" == *"warn message" ]]
    run logging error "error message"
    [[ "$output" == *"error message" ]]

    logging_config error
    echo "output=$output."
    run logging debug "debug message"
    [[ "$output" == *"" ]]
    run logging info "info message"
    [[ "$output" == *"" ]]
    run logging warn "warn message"
    [[ "$output" == *"" ]]
    run logging error "error message"
    [[ "$output" == *"error message" ]]


    logging_config 3
    echo "output=$output."
    run logging debug "debug message"
    [[ "$output" == *"debug message" ]]
    run logging info "info message"
    [[ "$output" == *"info message" ]]
    run logging warn "warn message"
    [[ "$output" == *"warn message" ]]
    run logging error "error message"
    [[ "$output" == *"error message" ]]

    logging_config 2
    echo "output=$output."
    run logging debug "debug message"
    [[ "$output" == *"" ]]
    run logging info "info message"
    [[ "$output" == *"info message" ]]
    run logging warn "warn message"
    [[ "$output" == *"warn message" ]]
    run logging error "error message"
    [[ "$output" == *"error message" ]]

    logging_config 1
    echo "output=$output."
    run logging debug "debug message"
    [[ "$output" == *"" ]]
    run logging info "info message"
    [[ "$output" == *"" ]]
    run logging warn "warn message"
    [[ "$output" == *"warn message" ]]
    run logging error "error message"
    [[ "$output" == *"error message" ]]

    logging_config 0
    echo "output=$output."
    run logging debug "debug message"
    [[ "$output" == *"" ]]
    run logging info "info message"
    [[ "$output" == *"" ]]
    run logging warn "warn message"
    [[ "$output" == *"" ]]
    run logging error "error message"
    [[ "$output" == *"error message" ]]

    logging debug "debug should be hidden"
    logging info " info should be hidden"
    logging warn "warn ok"
    logging error "error ok"

}
