#!/usr/bin/env bats

setup() {
    source bin/modules/argparsing

    source bin/modules/logging
    logging_config debug
}

quote_args() {
    local words=()
    for word in $@; do
        # If the word is a negative number (integer or floating point, optionally with exponent)
        # if [[ "$word" =~ ^-[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
        #     words+=("'$word'")
        # # Otherwise, if it starts with a dash (an option) leave it unquoted
        # elif [[ "$word" == -* ]]; then
        if [[ "$word" == -* ]]; then
            words+=("$word")
        else
            words+=("'$word'")
        fi
    done
    # Join the array elements with a space.
    IFS=" "
    echo "${words[*]}"
    unset IFS
}

roundtrip() {
    set -eo pipefail
    local spec="$1"
    local known="$2"
    local unknown="$3"
    # override the expected output?
    local expect_known="${4:-$(quote_args $known)}"
    local expect_unknown="${5:-$(quote_args $unknown)}"
    # add a leading space if any content
    expect_known=${expect_known:+ $expect_known}
    expect_unknown=${expect_unknown:+ $expect_unknown}

    echo "roundtrip("
    echo "   spec='$spec'"
    echo "   known='$known', expect='$expect_known'"
    echo "   unknown='$unknown', expect='$expect_unknown'"
    echo ")..."

    run ./bin/modules/wargparse.py "$spec" $known $unknown
    [ "$status" -eq 0 ]
    logging debug "wargparse->$output"
    input="$output"

    echo "input='$input'"
    run argparsing_args "$input" known
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    echo "expect_known='$expect_known'"
    [ "$output" == "$expect_known" ]

    run argparsing_args "$input" unknown
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    echo "expect_unknown='$expect_unknown'"
    [ "$output" == "$expect_unknown" ]

    run argparsing_args "$input"
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect="$expect_known$expect_unknown"
    echo "expect both='$expect'"
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
}

@test "argpasing can remove" {

    run argparsing_argparse '{"arguments":[{"names":["--how-many"]}, {"names":["--too-many"]}]}' \
        --how-many 1 --too-many 100 --hello
    input="$output"
    [ "$status" -eq 0 ]

    # run argparsing_ "$input" known
    # echo "status=$status"
    # echo "output='$output'"
    # [ "$status" -eq 0 ]
    # expect='{"known":[],"unknown":["--hello"]}'
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

@test "argpasing can test" {

    run argparsing_argparse '{"arguments":[{"names":["--how-many"]}, {"names":["--too-many"]}]}' \
        --how-many 1 --too-many 100 --hello
    input="$output"

    run argparsing_has "$input" how_many
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect=''
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    run argparsing_has "$input" '--hello'
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 1 ]
    expect=''
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    argparsing_has "$input" how_many
    argparsing_has "$input" hello || true
    # $(argparsing_has hello ) && true # should fail - it's just to test that the above two tests work

    argparsing_has "$input" how_many
    ! argparsing_has "$input" hello
}

@test "argpasing can merge" {

    run argparsing_argparse '{"arguments":[{"names":["--how-many"]}, {"names":["--too-many"]}]}' \
        --how-many 1 --too-many 100 --hello
    input1="$output"
    [ "$status" -eq 0 ]

    run argparsing_argparse '{"arguments":[{"names":["--how-many"]}, {"names":["--too-many"]}, {"names":["--too-little"]}]}' \
        --how-many 2 --too-little 0 --hello --goodbye
    input2="$output"
    [ "$status" -eq 0 ]

    run argparsing_merge "$input1" "$input2"
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known":{"how_many":{"value":"2","origin":"--how-many"},"too_many":{"value":"100","origin":"--too-many"},"too_little":{"value":"0","origin":"--too-little"}},"unknown":["--hello","--goodbye"]}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    run argparsing_merge '{"known": [], "unknown": ["a"]}' '{"known": [], "unknown": []}'
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known":[],"unknown":[]}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    run argparsing_merge '{}' '{}'
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known":[],"unknown":[]}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

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

    # run argparsing_merge '{"known": [], "unknown": ["a"]}' '{"known": [], "unknown": []}'
    # echo "status=$status"
    # echo "output='$output'"
    # [ "$status" -eq 0 ]
    # expect='{"known":[],"unknown":[]}'
    # echo "expect='$expect'"
    # [ "$output" == "$expect" ]

    # run argparsing_merge '{}' '{}'
    # echo "status=$status"
    # echo "output='$output'"
    # [ "$status" -eq 0 ]
    # expect='{"known":[],"unknown":[]}'
    # echo "expect='$expect'"
    # [ "$output" == "$expect" ]

}


# @test "argpasing can keep" {
#     run argparsing_argparse '{"arguments":[{"names":["--how-many"]}, {"names":["--too-many"]}]}' \
#         '--how-many 1 --too-many 100' '--hello'
#     input="$output"
#     run argparsing_keep "$input" known
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     expect='{"known":{"how_many":{"value":null,"origin":null},"too_many":{"value":null,"origin":null}}}'
#     echo "expect='$expect'"
#     [ "$output" == "$expect" ]
# }

# @test "has can count" {
#     run argparsing_has --private-key --
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == "0" ]

#     run argparsing_has --private-key -- --unknown
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == "0" ]

#     run argparsing_has --private-key -- --private-key 'not eek'
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == "1" ]

#     run argparsing_has --p -- -p -p 'not eek'
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == "0" ]

#     run argparsing_has -p -- -p -p 'not eek'
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == "2" ]

# }


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

# @test "getopt / remove_unknowns can parse args" {

#     quote="'"
#     extra_options="--hello world --long-option -o short-option -s"

#     for cmd in "argparsing_getopt" "argparsing_remove_unknowns"; do
#         logging debug "running $cmd..."

#         if [[ "$cmd" == "argparsing_getopt" ]]; then
#             # extra_output=" -- '' '--hello' 'world' '--long-option' '-o' 'short-option' '-s'"
#             extra_output=" -- 'world' 'short-option'"
#         else
#             extra_output=""
#         fi
#         # no args
#         run $cmd
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         if [[ "$cmd" == "argparsing_getopt" ]]; then
#             [ "$output" == " --" ] # everything is treated as an unknown
#         else
#             [ "$output" == "" ]
#         fi
#         # no known args
#         run $cmd -- $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         # TODO: replace getopt with a python parsed calliningto arg parse
#         # this gives a more robust and portable solution.
#         [ "$status" -eq 0 ]
#         [ "$output" == "$extra_output" ]

#         ############
#         # one short switch without
#         run $cmd -o a -- $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == "$extra_output" ]

#             # one short switch with
#         run $cmd -o a -- $extra_options -a
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -a$extra_output" ]

#         # one short switch with
#         run $cmd -o a -- -a $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -a$extra_output" ]

#         # one short option with, value
#         run $cmd -o a -- -aa $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -a -a$extra_output" ]


#         # one short option without
#         run $cmd -o a: -- $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == "$extra_output" ]

#         # one short option with, no value
#         run $cmd -o a: -- -a -x $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -a '-x'$extra_output" ] # takes value even though it's an option itself!

#         # one short option with, value
#         run $cmd -o a: -- -a value $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -a 'value'$extra_output" ]

#         # one short option with, value
#         run $cmd -o a: -- -a=value $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -a '=value'$extra_output" ]

#         # one short option with, value
#         run $cmd -o a: -- -avalue $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -a 'value'$extra_output" ]

#         # one short option with, value
#         run $cmd -o a: -- -aa $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -a 'a'$extra_output" ]

#         #################
#         # one long switch without
#         run $cmd -l switch -- $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == "$extra_output" ]

#         # one long switch with
#         run $cmd -l switch -- --switch $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " --switch$extra_output" ]

#         # one long option with, duplicate
#         run $cmd -l switch -- --switch --switch $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " --switch --switch$extra_output" ]


#         # one long option without
#         run $cmd -l option: -- $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == "$extra_output" ]

#         # one long option with, no value
#         run $cmd -l option: -- --option -x $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " --option '-x'$extra_output" ] # takes value even though it's an option itself!

#         # one long option with, value
#         run $cmd -l option: -- --option value $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " --option 'value'$extra_output" ]

#         # one long option with, value
#         run $cmd -l option: -- --option=value $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " --option 'value'$extra_output" ]

#         # one long option with, value
#         run $cmd -l option: -- --optionvalue $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == "$extra_output" ]

#         # one long option with, value
#         run $cmd -l option: -- --option= value $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " --option ''${extra_output/ -- / -- ${quote}value${quote} }" ]

#         # one long option with, value
#         run $cmd -l option: -- --option =value $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " --option '=value'$extra_output" ]

#         # one long option with, value
#         run $cmd -l option: -- --option --option $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " --option '--option'$extra_output" ]

#         # one long option with, multiple values
#         run $cmd -l option: -- --option value1,value2 $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " --option 'value1,value2'$extra_output" ]

#         # one long option with, multiple values
#         run $cmd -l option: -- --option=value1,value2 $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " --option 'value1,value2'$extra_output" ]

#         # one long option with, multiple values
#         run $cmd -l option: -- --option=value1 value2 $extra_options
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " --option 'value1'${extra_output/ -- / -- ${quote}value2${quote} }" ]

#     done
# }

# @test "getopt / remove_unknowns handles quoting of values" {
#     quote="'"

#     for cmd in "argparsing_getopt" "argparsing_remove_unknowns"; do
#         logging debug "running $cmd..."

#         if [[ "$cmd" == "argparsing_getopt" ]]; then
#             extra_output=" --"
#         else
#             extra_output=""
#         fi

#         run $cmd -o o: -l option: -- -o ovalue --option optionvalue
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -o 'ovalue' --option 'optionvalue'$extra_output" ]

#         run $cmd -o o: -l option: -- -o 'ovalue' --option 'optionvalue'
#         echo "status=$status"
#         echo "output=\"$output\""
#         [ "$status" -eq 0 ]
#         [ "$output" == " -o 'ovalue' --option 'optionvalue'$extra_output" ]

#         run $cmd -o o: -l option: -- -o 'o value' --option 'option value'
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -o 'o value' --option 'option value'$extra_output" ]

#         run $cmd -o o: -l option: -- -o o\ value --option option\ value
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -o 'o value' --option 'option value'$extra_output" ]

#         run $cmd -o o: -l option: -- -o "ovalue" --option "optionvalue"
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -o 'ovalue' --option 'optionvalue'$extra_output" ]

#         run $cmd -o o: -l option: -- -o "ovalue" --option "optionvalue"
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -o 'ovalue' --option 'optionvalue'$extra_output" ]

#         # nasty one to fool any regex about the end of the line
#         # getopt doesn't work for the following (value with embedded " -- ")
#         run $cmd -o o: -l option: -- -o 'o -- value' --option "option -- value"
#         echo "status=$status"
#         echo "output='$output'"
#         [ "$status" -eq 0 ]
#         [ "$output" == " -o 'o -- value' --option 'option -- value'$extra_output" ]

#     done
# }

# @test "extract_getopt_spec_from_hashhash can extract arg specs" {
#     run argparsing_extract_getopt_spec_from_hashhash lib/bao-base/test/bin/modules/argparsing.spec
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == "-o szo:p:q::r::wx:y:: -l switch,zwitch,option:,param:,query::,random::,wei-rd1,wei-rd2,wei--rd1:,wei--rd2:,_weird1::,_weird2::" ]
# }


# @test "parse_to_json can convert straight forward args to json" {
#     skip
#     # single valueless arg
#     run argparsing_parse_to_json -s
#     [ "$status" -eq 0 ]
#     echo "output='$output'"
#     [ "$output" == '{"-s":[]}' ]

#     run argparsing_parse_to_json --switch
#     [ "$status" -eq 0 ]
#     echo "output='$output'"
#     [ "$output" == '{"--switch":[]}' ]

#     run argparsing_parse_to_json -z
#     [ "$status" -eq 0 ]
#     echo "output='$output'"
#     [ "$output" == '{"-z":[]}' ]

#     run argparsing_parse_to_json --zwitch
#     [ "$status" -eq 0 ]
#     echo "output='$output'"
#     [ "$output" == '{"--zwitch":[]}' ]

#     run argparsing_parse_to_json -o xxx
#     [ "$status" -eq 0 ]
#     echo "output='$output'"
#     [ "$output" == '{"-o":["xxx"]}' ]

#     run argparsing_parse_to_json --option yyy
#     [ "$status" -eq 0 ]
#     echo "output='$output'"
#     [ "$output" == '{"--option":["yyy"]}' ]

#     run argparsing_parse_to_json -p zzz
#     [ "$status" -eq 0 ]
#     echo "output='$output'"
#     [ "$output" == '{"-p":["zzz"]}' ]

#     run argparsing_parse_to_json -m a bb ccc
#     [ "$status" -eq 0 ]
#     echo "output='$output'"
#     [ "$output" == '{"-m":["a","bb","ccc"]}' ]

#     run argparsing_parse_to_json -M "a" "b b" ccc
#     [ "$status" -eq 0 ]
#     echo "output='$output'"
#     [ "$output" == '{"-M":["a","b b","ccc"]}' ]

#     run argparsing_parse_to_json --many "a" "b b" ccc
#     [ "$status" -eq 0 ]
#     echo "output='$output'"
#     [ "$output" == '{"--many":["a","b b","ccc"]}' ]

#     run argparsing_parse_to_json --random some
#     [ "$status" -eq 0 ]
#     echo "output='$output'"
#     [ "$output" == '{"--random":["some"]}' ]

#     run argparsing_parse_to_json --random
#     [ "$status" -eq 0 ]
#     echo "output='$output'"
#     [ "$output" == '{"--random":[]}' ]
# }

# TODO: check other test args, e.g. [VALUE...] ones
# TODO: check what happens to unrecognised args
# TODO: check what happens when incorrect argument counts are applied
