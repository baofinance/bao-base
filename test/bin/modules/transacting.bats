#!/usr/bin/env bats

# setup() {
# }

@test "transacting_config can read the defaultable args" {
    set -e
    source lib/bao-base/bin/modules/transacting
    logging_config debug

    transacting_config
    run transacting_default_options
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect=""
    echo "expect='$expect'"
    [ "$output" == "$expect" ]
    echo "----"

    transacting_config --private-key eek
    run transacting_default_options
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect=" --private-key 'eek'"
    echo "expect='$expect'"
    [ "$output" == "$expect" ]
    echo "----"

    # test defaulting from env
    export ETHERSCAN_API_KEY="etherscankey"
    transacting_config
    run transacting_default_options
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect=" --etherscan-api-key 'etherscankey'"
    echo "expect='$expect'"
    [ "$output" == "$expect" ]
    ETHERSCAN_API_KEY=
    echo "----"

    # missing value
    transacting_config --rpc-url
    status=$?
    [ "$status" -eq 0 ] # TODO: this should generate an error
    run transacting_default_options
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect=""
    echo "expect='$expect'"
    [ "$output" == "$expect" ]
    echo "----"

    transacting_config --rpc-url xyz
    run transacting_default_options
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect=" --rpc-url 'xyz'"
    echo "expect='$expect'"
    [ "$output" == "$expect" ]
    echo "----"

    transacting_config --etherscan-api-key xyz
    run transacting_default_options
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect=" --etherscan-api-key 'xyz'"
    echo "expect='$expect'"
    [ "$output" == "$expect" ]
    echo "----"

    transacting_config --log
    run transacting_default_options
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect=""
    echo "expect='$expect'"
    [ "$output" == "$expect" ]
    echo "----"
}



# @test "_transacting_getopt can read the standard args for transacting" {
#     # single valueless arg
#     run _getopt_to_json --log
#     [ "$status" -eq 0 ]
#     echo "output=$output"
#     [ "$output" == '{"--verify":""}' ]
# }

# @test "_transacting_getopt can read the standard args for transacting" {
#     # single valueless arg
#     run _transacting_getopt --verify
#     [ "$status" -eq 0 ]
#     echo "output=$output"
#     [ "$output" == '{"--verify":""}' ]

#     # single string value arg
#     run _transacting_getopt --rpc-url local
#     [ "$status" -eq 0 ]
#     echo "output=$output"
#     [ "$output" == '{"--rpc-url":"local"}' ]

#     # single string = value arg
#     run _transacting_getopt --rpc-url=local
#     [ "$status" -eq 0 ]
#     echo "output=$output"
#     [ "$output" == '{"--rpc-url":"local"}' ]

#     # single number value arg - not treated differently
#     run _transacting_getopt --private-key 123
#     [ "$status" -eq 0 ]
#     echo "output=$output"
#     [ "$output" == '{"--private-key":"123"}' ]

#     # single special character value arg - not treated differently
#     run _transacting_getopt --etherscan-api-key="hello { } :"
#     [ "$status" -eq 0 ]
#     echo "output=$output"
#     [ "$output" == '{"--etherscan-api-key":"hello { } :"}' ]
# }

# @test "_transacting_getopt can detect errors" {

#     # unexpected value
#     # TODO: getopt doesn't fail for this:
#     # run _transacting_getopt --verify=eek
#     # [ "$status" -eq 1 ]

#     # unexpected no value
#     run _transacting_getopt --rpc-url
#     [ "$status" -eq 1 ]

#     # unexpected no value
#     run _transacting_getopt --rpc-url --verify
#     [ "$status" -eq 1 ]



#     # single number value arg - not treated differently
#     run _transacting_getopt --private-key=123
#     [ "$status" -eq 0 ]
#     echo "output=$output"
#     [ "$output" == '{"--private-key":"123"}' ]

#     # single special character value arg - not treated differently
#     run _transacting_getopt --etherscan-api-key="hello { } :"
#     [ "$status" -eq 0 ]
#     echo "output=$output"
#     [ "$output" == '{"--etherscan-api-key":"hello { } :"}' ]
# }

# @test "_deploying_convert_args_to_yaml function handles weird args" {
#     # null input
#     run _transacting_getopt
#     [ "$status" -eq 0 ]
#     echo "output=$output"
#     [ "$output" == '{}' ]

#     run _transacting_getopt --rpc-url=world=as=one
#     [ "$status" -eq 0 ]
#     echo "output=$output"
#     [ "$output" == '{"--rpc-url":"world=as=one"}' ]

#     run _transacting_getopt --rpc-url =world=as=one
#     [ "$status" -eq 0 ]
#     echo "output=$output"
#     [ "$output" == '{"--rpc-url":"=world=as=one"}' ]
# }
