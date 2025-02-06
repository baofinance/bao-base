#!/usr/bin/env bats

setup() {
    source lib/bao-base/bin/modules/argparsing

    source lib/bao-base/bin/modules/logging
    logging_config debug
}

@test "getopt / remove_unknowns can parse args" {

    quote="'"
    extra_options="--hello world --long-option -o short-option -s"

    for cmd in "argparsing_getopt" "argparsing_remove_unknowns"; do
        logging debug "running $cmd..."

        if [[ "$cmd" == "argparsing_getopt" ]]; then
            # extra_output=" -- '' '--hello' 'world' '--long-option' '-o' 'short-option' '-s'"
            extra_output=" -- 'world' 'short-option'"
        else
            extra_output=""
        fi
        # no args
        run $cmd
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        if [[ "$cmd" == "argparsing_getopt" ]]; then
            [ "$output" == " --" ] # everything is treated as an unknown
        else
            [ "$output" == "" ]
        fi
        # no known args
        run $cmd -- $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == "$extra_output" ]

        ############
        # one short switch without
        run $cmd -o a -- $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == "$extra_output" ]

            # one short switch with
        run $cmd -o a -- $extra_options -a
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -a$extra_output" ]

        # one short switch with
        run $cmd -o a -- -a $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -a$extra_output" ]

        # one short option with, value
        run $cmd -o a -- -aa $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -a -a$extra_output" ]


        # one short option without
        run $cmd -o a: -- $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == "$extra_output" ]

        # one short option with, no value
        run $cmd -o a: -- -a -x $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -a '-x'$extra_output" ] # takes value even though it's an option itself!

        # one short option with, value
        run $cmd -o a: -- -a value $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -a 'value'$extra_output" ]

        # one short option with, value
        run $cmd -o a: -- -a=value $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -a '=value'$extra_output" ]

        # one short option with, value
        run $cmd -o a: -- -avalue $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -a 'value'$extra_output" ]

        # one short option with, value
        run $cmd -o a: -- -aa $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -a 'a'$extra_output" ]

        #################
        # one long switch without
        run $cmd -l switch -- $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == "$extra_output" ]

        # one long switch with
        run $cmd -l switch -- --switch $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " --switch$extra_output" ]

        # one long option with, duplicate
        run $cmd -l switch -- --switch --switch $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " --switch --switch$extra_output" ]


        # one long option without
        run $cmd -l option: -- $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == "$extra_output" ]

        # one long option with, no value
        run $cmd -l option: -- --option -x $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " --option '-x'$extra_output" ] # takes value even though it's an option itself!

        # one long option with, value
        run $cmd -l option: -- --option value $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " --option 'value'$extra_output" ]

        # one long option with, value
        run $cmd -l option: -- --option=value $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " --option 'value'$extra_output" ]

        # one long option with, value
        run $cmd -l option: -- --optionvalue $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == "$extra_output" ]

        # one long option with, value
        run $cmd -l option: -- --option= value $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " --option ''${extra_output/ -- / -- ${quote}value${quote} }" ]

        # one long option with, value
        run $cmd -l option: -- --option =value $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " --option '=value'$extra_output" ]

        # one long option with, value
        run $cmd -l option: -- --option --option $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " --option '--option'$extra_output" ]

        # one long option with, multiple values
        run $cmd -l option: -- --option value1,value2 $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " --option 'value1,value2'$extra_output" ]

        # one long option with, multiple values
        run $cmd -l option: -- --option=value1,value2 $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " --option 'value1,value2'$extra_output" ]

        # one long option with, multiple values
        run $cmd -l option: -- --option=value1 value2 $extra_options
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " --option 'value1'${extra_output/ -- / -- ${quote}value2${quote} }" ]

    done
}

@test "getopt / remove_unknowns handles quoting of values" {
    quote="'"

    for cmd in "argparsing_getopt" "argparsing_remove_unknowns"; do
        logging debug "running $cmd..."

        if [[ "$cmd" == "argparsing_getopt" ]]; then
            extra_output=" --"
        else
            extra_output=""
        fi

        run $cmd -o o: -l option: -- -o ovalue --option optionvalue
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -o 'ovalue' --option 'optionvalue'$extra_output" ]

        run $cmd -o o: -l option: -- -o 'ovalue' --option 'optionvalue'
        echo "status=$status"
        echo "output=\"$output\""
        [ "$status" -eq 0 ]
        [ "$output" == " -o 'ovalue' --option 'optionvalue'$extra_output" ]

        run $cmd -o o: -l option: -- -o 'o value' --option 'option value'
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -o 'o value' --option 'option value'$extra_output" ]

        run $cmd -o o: -l option: -- -o o\ value --option option\ value
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -o 'o value' --option 'option value'$extra_output" ]

        run $cmd -o o: -l option: -- -o "ovalue" --option "optionvalue"
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -o 'ovalue' --option 'optionvalue'$extra_output" ]

        run $cmd -o o: -l option: -- -o "ovalue" --option "optionvalue"
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -o 'ovalue' --option 'optionvalue'$extra_output" ]

        # nasty one to fool any regex about the end of the line
        # getopt doesn't work for the following (value with embedded " -- ")
        run $cmd -o o: -l option: -- -o 'o -- value' --option "option -- value"
        echo "status=$status"
        echo "output='$output'"
        [ "$status" -eq 0 ]
        [ "$output" == " -o 'o -- value' --option 'option -- value'$extra_output" ]

    done
}

@test "extract_getopt_spec_from_hashhash can extract arg specs" {
    run argparsing_extract_getopt_spec_from_hashhash lib/bao-base/test/bin/modules/argparsing.spec
    echo "status=$status"
    echo "output='$output'"
    [ "$status" -eq 0 ]
    [ "$output" == "-o szo:p:q::r::wx:y:: -l switch,zwitch,option:,param:,query::,random::,wei-rd1,wei-rd2,wei--rd1:,wei--rd2:,_weird1::,_weird2::" ]
}


@test "parse_to_json can convert straight forward args to json" {
    skip
    # single valueless arg
    run argparsing_parse_to_json -s
    [ "$status" -eq 0 ]
    echo "output='$output'"
    [ "$output" == '{"-s":[]}' ]

    run argparsing_parse_to_json --switch
    [ "$status" -eq 0 ]
    echo "output='$output'"
    [ "$output" == '{"--switch":[]}' ]

    run argparsing_parse_to_json -z
    [ "$status" -eq 0 ]
    echo "output='$output'"
    [ "$output" == '{"-z":[]}' ]

    run argparsing_parse_to_json --zwitch
    [ "$status" -eq 0 ]
    echo "output='$output'"
    [ "$output" == '{"--zwitch":[]}' ]

    run argparsing_parse_to_json -o xxx
    [ "$status" -eq 0 ]
    echo "output='$output'"
    [ "$output" == '{"-o":["xxx"]}' ]

    run argparsing_parse_to_json --option yyy
    [ "$status" -eq 0 ]
    echo "output='$output'"
    [ "$output" == '{"--option":["yyy"]}' ]

    run argparsing_parse_to_json -p zzz
    [ "$status" -eq 0 ]
    echo "output='$output'"
    [ "$output" == '{"-p":["zzz"]}' ]

    run argparsing_parse_to_json -m a bb ccc
    [ "$status" -eq 0 ]
    echo "output='$output'"
    [ "$output" == '{"-m":["a","bb","ccc"]}' ]

    run argparsing_parse_to_json -M "a" "b b" ccc
    [ "$status" -eq 0 ]
    echo "output='$output'"
    [ "$output" == '{"-M":["a","b b","ccc"]}' ]

    run argparsing_parse_to_json --many "a" "b b" ccc
    [ "$status" -eq 0 ]
    echo "output='$output'"
    [ "$output" == '{"--many":["a","b b","ccc"]}' ]

    run argparsing_parse_to_json --random some
    [ "$status" -eq 0 ]
    echo "output='$output'"
    [ "$output" == '{"--random":["some"]}' ]

    run argparsing_parse_to_json --random
    [ "$status" -eq 0 ]
    echo "output='$output'"
    [ "$output" == '{"--random":[]}' ]
}

# TODO: check other test args, e.g. [VALUE...] ones
# TODO: check what happens to unrecognised args
# TODO: check what happens when incorrect argument counts are applied
