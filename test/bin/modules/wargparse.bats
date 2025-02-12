#!/usr/bin/env bats

setup() {
    source bin/modules/logging
    logging_config debug
}

@test "wargparse can parse arguments" {
    extra_options="--hello world --long-option -o short-option -s"
    extra_output='"unknown": ["--hello", "world", "--long-option", "-o", "short-option", "-s"]'

    # prints help if nothing supplied
    run ./bin/modules/wargparse.py
    echo "status=$status"
    [ "$status" -eq 1 ]

    # no args
    run ./bin/modules/wargparse.py '{}'
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    [ "$output" == '{"known": {}, "unknown": []}' ]

    # no known args
    run ./bin/modules/wargparse.py '{}' $extra_options
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known": {}, '$extra_output'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    ############
    # one short switch without
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"], "action": "store_true"}]}' $extra_options
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known": {"a": {"value": false, "origin": null}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a", "--alpha"], "action": "store_true"}]}' $extra_options
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known": {"alpha": {"value": false, "origin": null}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # one short switch with
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"], "action": "store_true"}]}'  $extra_options -a
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known": {"a": {"value": true, "origin": "-a"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # one short switch with
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a", "--alpha"], "action": "store_true"}]}'  $extra_options -a
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known": {"alpha": {"value": true, "origin": "-a"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # one short switch with, value
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"]}]}'  $extra_options -aa
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known": {"a": {"value": "a", "origin": "-a"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # one short count without, i.e. 0
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-c"], "action": "count"}]}'  $extra_options
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known": {"c": {"value": null, "origin": null}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # one short count without, i.e. 1
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-c"], "action": "count"}]}'  $extra_options \
        -c
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known": {"c": {"value": 1, "origin": "-c"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # one short count without, i.e. 1
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-c"], "action": "count"}]}'  $extra_options \
        -cc
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known": {"c": {"value": 2, "origin": "-c -c"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # one short count without, i.e. 1
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-c"], "action": "count"}]}'  $extra_options \
        -c -c
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known": {"c": {"value": 2, "origin": "-c -c"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # # one short option without
    # run ./bin/modules/wargparse.py -o a: -- $extra_opt    # one short count without, i.e. 1
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-c", "--count"], "action": "count"}]}'  $extra_options \
        -c --count
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    expect='{"known": {"count": {"value": 2, "origin": "-c --count"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # one short option with, no value
    # run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"]}]}' -a -x $extra_options
    # echo "status=$status"
    # echo "output='$output'"
    # expect='{"known": {"a": {"value": "-x", "origin": "-a"}}, '"$extra_output"'}'
    # echo "expect='$expect'"
    # [ "$output" == "$expect" ]  # takes value even though it's an option itself!

    # one short option with,
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"]}]}' $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"a": {"value": null, "origin": null}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]  # takes value even though it looks like an option itself!

    # one short option with, no value
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"]}]}' -a -1 $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"a": {"value": "-1", "origin": "-a"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]  # takes value even though it looks like an option itself!

    # one short option with, value
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"]}]}' -a value $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"a": {"value": "value", "origin": "-a"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # one short option with, =value
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"]}]}' -a=value $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"a": {"value": "value", "origin": "-a"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # one short option with, =value
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"]}]}' -avalue $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"a": {"value": "value", "origin": "-a"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # one short option with, value
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"]}]}' -avalue $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"a": {"value": "value", "origin": "-a"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]


    # #################
    # # one long switch without
    # run ./bin/modules/wargparse.py -l switch -- $extra_options
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["--switch"], "action": "store_true"}]}'  $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"switch": {"value": false, "origin": null}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # # one long switch with
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["--switch"], "action": "store_true"}]}' --switch $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"switch": {"value": true, "origin": "--switch"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # # one long option with, duplicate
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["--switch"], "action": "store_true"}]}' --switch --switch $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"switch": {"value": true, "origin": "--switch"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]


    # # one long option without
    # run ./bin/modules/wargparse.py -l option: -- $extra_options
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["--option"]}]}' $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"option": {"value": null, "origin": null}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # # one long option with, no value
    # run ./bin/modules/wargparse.py -l option: -- --option -x $extra_options
    # echo "status=$status"
    # echo "output='$output'"
    # [ "$status" -eq 0 ]
    # [ "$output" == " --option '-x'$extra_output" ] # takes value even though it's an option itself!

    # # one long option with, value
    # run ./bin/modules/wargparse.py -l option: -- --option value $extra_options
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["--option"]}]}' --option value $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"option": {"value": "value", "origin": "--option"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # # one long option with, value
    # run ./bin/modules/wargparse.py -l option: -- --option=value $extra_options
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["--option"]}]}' --option=value $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"option": {"value": "value", "origin": "--option"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]


    # # one long option with, value
    # run ./bin/modules/wargparse.py -l option: -- --option =value $extra_options
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["--option"]}]}' --option =value $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"option": {"value": "=value", "origin": "--option"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # # one long option with, multiple values
    # run ./bin/modules/wargparse.py -l option: -- --option value1,value2 $extra_options
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["--option"]}]}' --option value1,value2 $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"option": {"value": "value1,value2", "origin": "--option"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # # one long option with, multiple values
    run ./bin/modules/wargparse.py '{"arguments":[{"names":["--option"]}]}' --option=value1,value2 $extra_options
    echo "status=$status"
    echo "output='$output'"
    expect='{"known": {"option": {"value": "value1,value2", "origin": "--option"}}, '"$extra_output"'}'
    echo "expect='$expect'"
    [ "$output" == "$expect" ]

    # # one long option with, multiple values
    # run ./bin/modules/wargparse.py -l option: -- --option=value1 value2 $extra_options

}


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

# # TODO: check other test args, e.g. [VALUE...] ones
# # TODO: check what happens to unrecognised args
# # TODO: check what happens when incorrect argument counts are applied
