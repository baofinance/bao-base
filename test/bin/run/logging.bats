#!/usr/bin/env bats

load ../../bats_helpers.sh

setup() {

    # Source the logging script
    source "./bin/run/logging"
    unset DEBUG
    unset LOGGING_SENSITIVE_TEXT
    # make logging go to std out
    export LOGGING_FILE_DESCRIPTOR=1
}

@test "_output function should output" {
    run _output TEST "This should be visible"
    expect --partial "TEST"
    expect --not --partial "bats"
    expect --partial "This should be visible"
}

@test "_output function should output debug info when DEBUG is set" {
    export DEBUG=
    run _output TEST "This should be visible"
    expect --partial "TEST"
    expect --partial "bats"
    expect --partial "This should be visible"
}

@test "debug function should not output when DEBUG is not set" {
    run debug "This should not be visible"
    expect ""
}

@test "debug function should output when script name is in DEBUG" {
    # Extract the script name from the current test file
    export DEBUG="test_functions.bash" # this is very BATS implementation specific
    run debug "Test debug message"
    expect --partial "DEBUG"
    expect --partial "Test debug message"
}

@test "info function should respect verbosity level" {
    # Test with low verbosity
    export BAO_BASE_VERBOSITY=1

    run info 1 "Should be visible with verbosity 1"
    expect --partial "Should be visible with verbosity 1"

    run info 2 "Should not be visible with verbosity 1"
    expect --partial --not "Should not be visible with verbosity 1"

    # Test with higher verbosity
    export BAO_BASE_VERBOSITY=2

    run info 1 "Should be visible with verbosity 2"
    expect --partial "Should be visible with verbosity 2"

    run info 2 "Should also be visible with verbosity 2"
    expect --not --partial "bats"
    expect --partial "Should also be visible with verbosity 2"

    export DEBUG=
    run info 2 "Should also be visible with verbosity 2"
    expect --partial "bats"

}

@test "error function should output and exit" {
    run bash -c "source ./bin/run/logging && error 'Test error message'"

    expect --failure --partial "ERROR"
    expect --failure --partial "Test error message"
}

@test "sensitive function should hide text in output" {
    run _output "TEST" "This contains SECRET_VALUE which should not be hidden"
    expect --partial "This contains SECRET_VALUE which should not be hidden"

    # Run sensitive and _output in the same process
    run bash -c "source './bin/run/logging' &&
                sensitive 'SECRET_VALUE' &&
                _output 'TEST' 'This contains SECRET_VALUE which should be hidden'"
    expect --partial "This contains ***hidden*** which should be hidden"

    # Run with custom replacement
    run bash -c "source './bin/run/logging' &&
                sensitive 'SECRET_VALUE' 'not secret text' &&
                _output 'TEST' 'This contains SECRET_VALUE which should be hidden'"
    expect --partial "This contains not secret text which should be hidden"

    # Test with showing sensitive text
    run bash -c "source './bin/run/logging' &&
                sensitive 'SECRET_VALUE' &&
                export LOGGING_SENSITIVE_TEXT='show' &&
                _output 'TEST' 'This contains SECRET_VALUE which should be shown'"
    expect --partial "This contains SECRET_VALUE which should be shown"

    export LOGGING_SENSITIVE_TEXT="show"
    _output "TEST" "This contains SECRET_VALUE which should be shown"
    expect --partial "This contains SECRET_VALUE which should be shown"
}

@test "multiline messages should be properly formatted" {
    # Create a message with actual newlines
    run _output "TEST" "First line
Second line
Third line"

    # First line should contain the label
    expect --head --partial "TEST"
    expect --head --partial "First line"
    expect --tail --partial "Third line"

    # second and third lines should be correctly indented
    local first_pos=$(echo "$output" | grep -b -o "First" | head -n 1 | cut -d: -f1)
    local expected_padding=$(printf "%${first_pos}s" "")

    readarray -t lines <<< "$output"
    [[ "${lines[1]}" == "${expected_padding}Second line" ]]
    [[ "${lines[2]}" == "${expected_padding}Third line" ]]
}

@test "multiline messages should be properly formatted even if DEBUG is set" {
    # Create a message with actual newlines
    export DEBUG=eek
    run _output "TEST" "First line
Second line
Third line"

    # First line should contain the label
    expect --head --partial "TEST"
    expect --head --partial "First line"
    expect --tail --partial "Third line"

    # second and third lines should be correctly indented
    local first_pos=$(echo "$output" | grep -b -o "First" | head -n 1 | cut -d: -f1)
    local expected_padding=$(printf "%${first_pos}s" "")

    readarray -t lines <<< "$output"
    [[ "${lines[1]}" == "${expected_padding}Second line" ]]
    [[ "${lines[2]}" == "${expected_padding}Third line" ]]
}

@test "debug_opts should extract dash-prefixed options from DEBUG" {
    export DEBUG="run,-v,-verbose,test"
    run debug_opts
    expect " -v -verbose"
}

@test "INFO multiline messages should be properly formatted" {
    # Create a message with actual newlines
    run info 0 "First line
Second line
Third line"

    # First line should contain the label
    expect --head --partial "INFO 0 "
    expect --head --partial "First line"
    expect --tail --partial "Third line"

    # second and third lines should be correctly indented
    local first_pos=$(echo "$output" | grep -b -o "First" | head -n 1 | cut -d: -f1)
    local expected_padding=$(printf "%${first_pos}s" "")

    readarray -t lines <<< "$output"
    [[ "${lines[1]}" == "${expected_padding}Second line" ]]
    [[ "${lines[2]}" == "${expected_padding}Third line" ]]
}