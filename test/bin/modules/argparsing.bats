#!/usr/bin/env bats

setup() {
    source lib/bao-base/bin/modules/argparsing
    logging_config debug
    export ARGPARSING_SPEC_FILE=lib/bao-base/test/bin/modules/argparsing.spec
}

@test "getopt can straight forward args to json" {
    # single valueless arg
    run parse_args_to_json -s
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '{"-s":[]}' ]

    run parse_args_to_json --switch
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '{"--switch":[]}' ]

    run parse_args_to_json -z
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '{"-z":[]}' ]

    run parse_args_to_json --zwitch
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '{"--zwitch":[]}' ]

    run parse_args_to_json -o xxx
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '{"-o":["xxx"]}' ]

    run parse_args_to_json --option yyy
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '{"--option":["yyy"]}' ]

    run parse_args_to_json -p zzz
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '{"-p":["zzz"]}' ]

    run parse_args_to_json -m a bb ccc
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '{"-m":["a","bb","ccc"]}' ]

    run parse_args_to_json -M "a" "b b" ccc
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '{"-M":["a","b b","ccc"]}' ]

    run parse_args_to_json --many "a" "b b" ccc
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '{"--many":["a","b b","ccc"]}' ]

    run parse_args_to_json --random some
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '{"--random":["some"]}' ]

    run parse_args_to_json --random
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == '{"--random":[]}' ]
}

# TODO: check other test args, e.g. [VALUE...] ones
# TODO: check what happens to unrecognised args
# TODO: check what happens when incorrect argument counts are applied
