#!/usr/bin/env bats

source test/bin/modules/bats-utils # for run_and_check

setup() {
    source bin/modules/argparsing

    source bin/modules/logging
    logging_config debug
}

quote_args() {
    local input="$1"
    # Use eval to have the shell break the input into words
    eval "local args=( $input )"
    local result=""
    for word in "${args[@]}"; do
        if [[ "$word" == -* ]]; then
            result+=" $word"
        else
            result+=" '$word'"
        fi
    done
    echo "${result# }" # remove the extra leading space, if any
}

roundtrip() {
    set -eo pipefail
    local spec="$1"
    local known="${2:-}"
    local unknown="${3:-}"
    # override the expected output?
    local expect_known=${4:-$(quote_args "$known")}
    local expect_unknown=${5:-$(quote_args "$unknown")}
    # add a leading space if any content
    expect_known=${expect_known:+ $expect_known}
    expect_unknown=${expect_unknown:+ $expect_unknown}

    echo "roundtrip("
    echo "   spec=$spec."
    echo "   known=$known, expect=$expect_known."
    echo "   unknown=$unknown, expect=$expect_unknown."
    echo ")..."

    eval "set -- $known $unknown"
    run ./bin/modules/wargparse.py "$spec" "$@"
    logging debug "wargparse->$output"
    [ "$status" -eq 0 ]
    input="$output"

    echo "input='$input'"
    run argparsing_args "$input" known
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    echo "expect='$expect_known'"
    [ "$output" == "$expect_known" ]

    run argparsing_args "$input" unknown
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    echo "expect='$expect_unknown'"
    [ "$output" == "$expect_unknown" ]

    run argparsing_args "$input"
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect="$expect_known$expect_unknown"
    echo "expect='$expect'"
    [ "$output" == "$expect" ]
}




@test "argparsing can round-trip" {
    # roundtrip '{}' ''
    # run ./bin/modules/wargparse.py --help

    roundtrip '{}' '' ''

    roundtrip '{}' '' '--hello world'

    roundtrip '{}' '' '--hello --how-many'

    roundtrip '{}' '' '--hello --how-many -1'

    roundtrip '{}' '' '-a --hello -b --how-many -1 -c'

    roundtrip '{"arguments":[{"names":["--how-many"]}, {"names":["--too-many"]}]}' \
        '--how-many 1 --too-many 100' '--hello'

    roundtrip '{"arguments":[{"names":["--how-many"]}]}' '--how-many -1' '--hello' "--how-many '-1'"

    # handle nulls
    roundtrip '{"arguments":[{"names":["--how-many"]}]}' '' '--hello'

    roundtrip '{"arguments":[{"names":["--how-many"]}]}' '--how-many 1' ''

    # handle defaults
    roundtrip '{"arguments":[{"names":["--how-many"], "default": "99"}, {"names":["--too-many"]}]}' \
        '--how-many 99 --too-many 100' '--hello'

    roundtrip '{"arguments":[{"names":["--how-many", "-m"], "default": "99"}, {"names":["--too-many"]}]}' \
        '--how-many 99 --too-many 100' '--hello'

    roundtrip '{"arguments":[{"names":["-m", "--how-many"], "default": "99"}, {"names":["--too-many"]}]}' \
        '-m 99 --too-many 100' '--hello'

    # positional args
    roundtrip '{"arguments": [{"names": ["file_contract"], "nargs":"*"}]}' \
        '' ''

    roundtrip '{"arguments": [{"names": ["file_contract"], "nargs":1}]}' \
        'a:b' ''

    # two given
    roundtrip '{"arguments": [{"names": ["file_contract"], "nargs":2}]}' \
        'a:b c:d' ''


}

@test "argparsing can round-trip positionals" {
    # positional
    roundtrip '{"arguments":[{"names":["positional"]}, {"names":["--optional"]}]}' \
        "'positional argument'" ''

    roundtrip '{"arguments":[{"names":["positional"]}, {"names":["--optional"]}]}' \
        "'positional argument' --optional 1 " '--hello world'

    roundtrip '{"arguments":[{"names":["positional"]}, {"names":["--optional"]}]}' \
        "--optional 1 'positional argument'" '--hello world' "'positional argument' --optional '1'"

    # empty, everything
    roundtrip ''
}

@test "argparsing can round-trip store_booleans" {
    # store_boolean
    run_and_check ./bin/modules/wargparse.py 0 \
        '{"known": {"aa": {"value": null, "origin": null, "default_origin": "--aa"}}, "unknown": []}' \
        '{"arguments":[{"names":["--aa","--no-aa"], "action": "store_boolean"}]}' \

    # present
    run_and_check ./bin/modules/wargparse.py 0 \
        '{"known": {"aa": {"value": true, "origin": "--aa"}}, "unknown": []}' \
        '{"arguments":[{"names":["--aa","--no-aa"], "action": "store_boolean"}]}' \
        --aa

    # no-present
    run_and_check ./bin/modules/wargparse.py 0 \
        '{"known": {"aa": {"value": false, "origin": "--no-aa"}}, "unknown": []}' \
        '{"arguments":[{"names":["--aa","--no-aa"], "action": "store_boolean"}]}' \
        --no-aa
}

@test "argparsing can do positional args" {
    run_and_check 'argparsing_argparse' 0 \
        '{"known":{"positional":{"value":"positional argument","origin":null},"optional":{"value":"1","origin":"--optional"}},"unknown":["--hello","world"]}' \
        '{"arguments":[{"names":["positional"]}, {"names":["--optional"]}]}' \
        --optional 1 'positional argument' --hello world

    # all positionals are required so you can't miss them
}

@test "argpasing can remove_unknown" {

    run argparsing_argparse '{"arguments":[{"names":["--how-many"]}, {"names":["--too-many"]}]}' \
        --how-many 1 --too-many 100 --hello
    input="$output"
    [ "$status" -eq 0 ]

    # run argparsing_ "$input" known
    # echo "status=$status"
    # echo "output='$output'"
    # [ "$status" -eq 0 ]
    # expect='{"known":{},"unknown":["--hello"]}'
    # echo "expect='$expect'"
    # [ "$output" == "$expect" ]

    run argparsing_remove_unknown "$input"
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known":{"how_many":{"value":"1","origin":"--how-many"},"too_many":{"value":"100","origin":"--too-many"}},"unknown":[]}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

}

@test "argpasing can test and extract" {

    run argparsing_argparse '{"arguments":[
        {"names": ["--how-many"]}, {"names": ["--too-many"]},
        {"names": ["positional"]},
        {"names": ["optionalpositional"], "nargs": "?"},
        {"names": ["missingoptionalpositional"], "nargs": "?"}
        ]}' \
        --how-many ask --too-many 100 "positional argument" optpos --hello
    input="$output"

    run_and_check argparsing_has 0 '' how_many "$input"
    run_and_check argparsing_value 0 ask how_many "$input"

    run_and_check argparsing_has 0 '' too_many "$input"
    run_and_check argparsing_value 0 100 too_many "$input"

    run_and_check argparsing_has 0 '' positional "$input"
    run_and_check argparsing_value 0 'positional argument' positional "$input"

    run_and_check argparsing_has 0 '' optionalpositional "$input"
    run_and_check argparsing_value 0 'optpos' optionalpositional "$input"

    run_and_check argparsing_has 1 '' missingoptionalpositional "$input"
    run_and_check argparsing_value 0 '' missingoptioalpositional "$input"


    # has doeesn't find unknowns
    run_and_check argparsing_has 1 '' hello "$input"
    run_and_check argparsing_has 1 '' '--hello' "$input"

    argparsing_has how_many "$input"
    argparsing_has hello "$input" || true
    # $(argparsing_has hello ) && true # should fail - it's just to test that the above two tests work

    argparsing_has how_many "$input"
    ! argparsing_has hello "$input"
}

@test "argpasing can merge" {

    # merges known by key, unknown is concatenated
    run_and_check argparsing_merge 0 '{"known":{},"unknown":["a"]}' '{"known": {}, "unknown": ["a"]}' '{"known": {}, "unknown": []}'

    run_and_check argparsing_merge 0 '{"known":{},"unknown":["a"]}' '{"known": {}, "unknown": []}' '{"known": {}, "unknown": ["a"]}'

    run_and_check argparsing_merge 0 '{"known":{},"unknown":["a","b"]}' '{"known": {}, "unknown": ["a"]}' '{"known": {}, "unknown": ["b"]}'

    run argparsing_argparse '{"arguments":[{"names":["--how-many"]}, {"names":["--too-many"]}]}' \
        --how-many 1 --too-many 100 --hello
    input1="$output"
    [ "$status" -eq 0 ]

    run argparsing_argparse '{"arguments":[{"names":["--how-many"]}, {"names":["--too-many"]}, {"names":["--too-little"]}]}' \
        --how-many 2 --too-little 0 --hello --goodbye
    input2="$output"
    [ "$status" -eq 0 ]

    run_and_check argparsing_merge 0 '{"known":{"how_many":{"value":"2","origin":"--how-many"},"too_many":{"value":"100","origin":"--too-many"},"too_little":{"value":"0","origin":"--too-little"}},"unknown":["--hello","--hello","--goodbye"]}' "$input1" "$input2"

    # not technically needed but checks for robustness - or maybe it shoud fail
    run_and_check argparsing_merge 0 '{"known":{},"unknown":[]}' '{}' '{}'
}

@test "argpasing can detect overlaps" {

    run argparsing_argparse '{"arguments":[{"names":["--how-many"]}, {"names":["--too-many"]}]}' \
        --how-many 1 --too-many 100 --hello
    input1="$output"
    [ "$status" -eq 0 ]

    run argparsing_argparse '{"arguments":[{"names":["--how-many"]}, {"names":["--too-many"]}, {"names":["--too-little"]}]}' \
        --how-many 2 --too-little 0 --hello --goodbye
    input2="$output"
    [ "$status" -eq 0 ]

    # output=$(argparsing_intersection "$input1" "$input2")
    run argparsing_intersection "$input1" "$input2"
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known":{"how_many":{"value":"1","origin":"--how-many"}},"unknown":["--hello"]}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    run argparsing_intersection "$input1" "$input2"
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known":{"how_many":{"value":"1","origin":"--how-many"}},"unknown":["--hello"]}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    run argparsing_intersection "$input2" "$input1"
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known":{"how_many":{"value":"2","origin":"--how-many"}},"unknown":["--hello"]}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    run argparsing_intersection "$input1" "$input1"
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect="$input1"
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    run argparsing_intersection "$input2" "$input2"
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect="$input2"
    echo "expect='$expect'"
    [ "$output" == "$expect" ]
}


@test "argparsing can count" {
    # zero
    run_and_check argparsing_argparse 0 '{"known":{},"unknown":[]}' '{"arguments":[{"names":["-v","--verbose"], "action": "store_count"}]}'

    # one
    run_and_check argparsing_argparse 0 '{"known":{"verbose":{"value":1,"origin":"--verbose"}},"unknown":[]}' '{"arguments":[{"names":["-v","--verbose"], "action": "store_count"}]}' \
        --verbose

    run_and_check argparsing_argparse 0 '{"known":{"verbose":{"value":1,"origin":"-v"}},"unknown":[]}' '{"arguments":[{"names":["-v","--verbose"], "action": "store_count"}]}' \
        -v

    # two
    run_and_check argparsing_argparse 0 '{"known":{"verbose":{"value":2,"origin":"--verbose --verbose"}},"unknown":[]}' '{"arguments":[{"names":["-v","--verbose"], "action": "store_count"}]}' \
        --verbose --verbose

    run_and_check argparsing_argparse 0 '{"known":{"verbose":{"value":2,"origin":"-v -v"}},"unknown":[]}' '{"arguments":[{"names":["-v","--verbose"], "action": "store_count"}]}' \
        -vv

    run_and_check argparsing_argparse 0 '{"known":{"verbose":{"value":2,"origin":"-v -v"}},"unknown":[]}' '{"arguments":[{"names":["-v","--verbose"], "action": "store_count"}]}' \
        -v -v

    # three
    run_and_check argparsing_argparse 0 '{"known":{"verbose":{"value":3,"origin":"-v -v -v"}},"unknown":[]}' '{"arguments":[{"names":["-v","--verbose"], "action": "store_count"}]}' \
        -vvv

    run_and_check argparsing_argparse 0 '{"known":{"verbose":{"value":3,"origin":"-v -v --verbose"}},"unknown":[]}' '{"arguments":[{"names":["-v","--verbose"], "action": "store_count"}]}' \
        -vv --verbose

    run_and_check argparsing_argparse 0 '{"known":{"verbose":{"value":3,"origin":"-v -v --verbose"}},"unknown":[]}' '{"arguments":[{"names":["-v","--verbose"], "action": "store_count"}]}' \
        -v -v --verbose

    # four
    run_and_check argparsing_argparse 0 '{"known":{"verbose":{"value":4,"origin":"-v -v -v -v"}},"unknown":[]}' '{"arguments":[{"names":["-v","--verbose"], "action": "store_count"}]}' \
        -vvvv

    run_and_check argparsing_argparse 0 '{"known":{"verbose":{"value":4,"origin":"-v -v --verbose --verbose"}},"unknown":[]}' '{"arguments":[{"names":["-v","--verbose"], "action": "store_count"}]}' \
        -vv --verbose --verbose

    run_and_check argparsing_argparse 0 '{"known":{"verbose":{"value":4,"origin":"--verbose -v -v --verbose"}},"unknown":[]}' '{"arguments":[{"names":["-v","--verbose"], "action": "store_count"}]}' \
        --verbose -v -v --verbose
}


# @test "default can default" {
#     run argparsing_default --option private-key -d eek
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == " --private-key 'eek'" ]

#     run argparsing_default --option private-key -d eek --
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == " --private-key 'eek'" ]

#     run argparsing_default --option private-key -d eek -- --unknown
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == " --unknown --private-key 'eek'" ]

#     run argparsing_default --option private-key -d eek -- --private-key 'not eek'
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == " --private-key 'not eek'" ]

#     run argparsing_default --option private-key --default eek --alias p -- -p 'not eek'
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == " -p 'not eek' --private-key 'eek'" ]

#     run argparsing_default --option private-key --default eek --alias p -- --p 'not eek'
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == " --p 'not eek'" ]

#     run argparsing_default -o p --default eek -a p -- -p 'not eek'
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == " -p 'not eek'" ]

#     run argparsing_default --option private-key -d eek -a p --alias key -- --key 'not eek'
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == " --key 'not eek'" ]

#     run argparsing_default --option private-key -d eek -a p --alias key -- -p 'not eek'
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == " -p 'not eek'" ]

# }


# @test "extract_getopt_spec_from_hashhash can extract arg specs" {
#     run argparsing_extract_getopt_spec_from_hashhash lib/bao-base/test/bin/modules/argparsing.spec
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == "-o szo:p:q::r::wx:y:: -l switch,zwitch,option:,param:,query::,random::,wei-rd1,wei-rd2,wei--rd1:,wei--rd2:,_weird1::,_weird2::" ]
# }


# TODO: check other test args, e.g. [VALUE...] ones
# TODO: check what happens when incorrect argument counts are applied
