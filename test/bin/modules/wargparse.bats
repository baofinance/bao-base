#!/usr/bin/env bats

source test/bin/modules/bats-utils # for run_and_check

setup() {
  source bin/modules/logging
  logging_config debug
}

@test "wargparse can extract positional args" {
  # nothing given
  run_and_check ./bin/modules/wargparse.py 0 \
    '{"known": {"file_contract": {"value": null, "origin": null, "default_origin": "file_contract"}}, "unknown": []}' \
    '{"arguments": [{"names": ["file_contract"], "nargs":"*"}]}'

  # one given
  run_and_check ./bin/modules/wargparse.py 0 \
    '{"known": {"file_contract": {"value": ["a:b"], "origin": null}}, "unknown": []}' \
    '{"arguments": [{"names": ["file_contract"], "nargs":1}]}' \
    a:b

  # two givem
  run_and_check ./bin/modules/wargparse.py 0 \
    '{"known": {"file_contract": {"value": ["a:b", "c:d"], "origin": null}}, "unknown": []}' \
    '{"arguments": [{"names": ["file_contract"], "nargs":2}]}' \
    a:b c:d

}

@test "wargparse handles explicit defaults" {
  run_and_check ./bin/modules/wargparse.py 0 \
    '{"known": {"a_a": {"value": "eek", "origin": null, "default_origin": "--a-a"}}, "unknown": []}' \
    '{"arguments":[{"names":["--a-a"], "default": "eek"}]}'

}

@test "wargparse supports --no- for boolean options" {

  # - doesn't work for short form options

  # run_and_check ./bin/modules/wargparse.py 0 \
  #     '{"known": {"a": {"value": null, "origin": null}}, "unknown": ["some"]}' \
  #     '{"arguments":[{"names":["-a"], "action": "store_boolean"}]}' \
  #     some

  # run_and_check ./bin/modules/wargparse.py 0 \
  #     '{"known": {"a": {"value": true, "origin": "-a"}}, "unknown": []}' \
  #     '{"arguments":[{"names":["-a"], "action": "store_boolean"}]}' \
  #     -a

  # -- long form must be at least 2 chars!

  # missing
  run_and_check ./bin/modules/wargparse.py 0 \
    '{"known": {"aa": {"value": null, "origin": null, "default_origin": "--aa"}}, "unknown": ["some"]}' \
    '{"arguments":[{"names":["--aa","--no-aa"], "action": "store_boolean"}]}' \
    some

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
  expect='{"known": {"a": {"value": false, "origin": null, "default_origin": "-a"}}, '"$extra_output"'}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ]

  run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a", "--alpha"], "action": "store_true"}]}' $extra_options
  echo "status=$status"
  echo "output='$output'"
  [ "$status" -eq 0 ]
  expect='{"known": {"alpha": {"value": false, "origin": null, "default_origin": "-a"}}, '"$extra_output"'}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ]

  # one short switch with
  run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"], "action": "store_true"}]}' $extra_options -a
  echo "status=$status"
  echo "output='$output'"
  [ "$status" -eq 0 ]
  expect='{"known": {"a": {"value": true, "origin": "-a"}}, '"$extra_output"'}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ]

  # one short switch with
  run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a", "--alpha"], "action": "store_true"}]}' $extra_options -a
  echo "status=$status"
  echo "output='$output'"
  [ "$status" -eq 0 ]
  expect='{"known": {"alpha": {"value": true, "origin": "-a"}}, '"$extra_output"'}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ]

  # one short switch with, value
  run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"]}]}' $extra_options -aa
  echo "status=$status"
  echo "output='$output'"
  [ "$status" -eq 0 ]
  expect='{"known": {"a": {"value": "a", "origin": "-a"}}, '"$extra_output"'}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ]

  # one short count without, i.e. 0
  run ./bin/modules/wargparse.py '{"arguments":[{"names":["-c"], "action": "count"}]}' $extra_options
  echo "status=$status"
  echo "output='$output'"
  [ "$status" -eq 0 ]
  expect='{"known": {"c": {"value": null, "origin": null, "default_origin": "-c"}}, '"$extra_output"'}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ]

  # one short count without, i.e. 1
  run ./bin/modules/wargparse.py '{"arguments":[{"names":["-c"], "action": "count"}]}' $extra_options \
    -c
  echo "status=$status"
  echo "output='$output'"
  [ "$status" -eq 0 ]
  expect='{"known": {"c": {"value": 1, "origin": "-c"}}, '"$extra_output"'}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ]

  # one short count without, i.e. 1
  run ./bin/modules/wargparse.py '{"arguments":[{"names":["-c"], "action": "count"}]}' $extra_options \
    -cc
  echo "status=$status"
  echo "output='$output'"
  [ "$status" -eq 0 ]
  expect='{"known": {"c": {"value": 2, "origin": "-c -c"}}, '"$extra_output"'}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ]

  # one short count without, i.e. 1
  run ./bin/modules/wargparse.py '{"arguments":[{"names":["-c"], "action": "count"}]}' $extra_options \
    -c -c
  echo "status=$status"
  echo "output='$output'"
  [ "$status" -eq 0 ]
  expect='{"known": {"c": {"value": 2, "origin": "-c -c"}}, '"$extra_output"'}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ]

  # # one short option without
  # run ./bin/modules/wargparse.py -o a: -- $extra_opt    # one short count without, i.e. 1
  run ./bin/modules/wargparse.py '{"arguments":[{"names":["-c", "--count"], "action": "count"}]}' $extra_options \
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
  expect='{"known": {"a": {"value": null, "origin": null, "default_origin": "-a"}}, '"$extra_output"'}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ] # takes value even though it looks like an option itself!

  # one short option with, no value
  run ./bin/modules/wargparse.py '{"arguments":[{"names":["-a"]}]}' -a -1 $extra_options
  echo "status=$status"
  echo "output='$output'"
  expect='{"known": {"a": {"value": "-1", "origin": "-a"}}, '"$extra_output"'}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ] # takes value even though it looks like an option itself!

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
  run ./bin/modules/wargparse.py '{"arguments":[{"names":["--switch"], "action": "store_true"}]}' $extra_options
  echo "status=$status"
  echo "output='$output'"
  expect='{"known": {"switch": {"value": false, "origin": null, "default_origin": "--switch"}}, '"$extra_output"'}'
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
  expect='{"known": {"option": {"value": null, "origin": null, "default_origin": "--option"}}, '"$extra_output"'}'
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

  run ./bin/modules/wargparse.py '{"arguments":[{"names":["--private-key"]}]}' --private-key eek
  echo "status=$status"
  echo "output='$output'"
  expect='{"known": {"private_key": {"value": "eek", "origin": "--private-key"}}, "unknown": []}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ]

  _transacting_arg_spec='{"arguments":[
    {"names":["--rpc-url"], "default": "local"},
    {"names":["--private-key"]},
    {"names":["--etherscan-api-key"]},
    {"names": ["--verify", "--no-verify"], "action": "store_boolean"}
    ]}'
  run ./bin/modules/wargparse.py "$_transacting_arg_spec" --private-key eek
  echo "status=$status"
  echo "output='$output'"
  expect='{"known": {"rpc_url": {"value": "local", "origin": null, "default_origin": "--rpc-url"}, "private_key": {"value": "eek", "origin": "--private-key"}, "etherscan_api_key": {"value": null, "origin": null, "default_origin": "--etherscan-api-key"}, "verify": {"value": null, "origin": null, "default_origin": "--verify"}}, "unknown": []}'
  echo "expect='$expect'"
  [ "$output" == "$expect" ]

  # # one long option with, multiple values
  # run ./bin/modules/wargparse.py -l option: -- --option=value1 value2 $extra_options

}

# @test "extract_getopt_spec_from_hashhash can extract arg specs" {
#     run argparsing_extract_getopt_spec_from_hashhash lib/bao-base/test/bin/modules/argparsing.spec
#     echo "status=$status"
#     echo "output='$output'"
#     [ "$status" -eq 0 ]
#     [ "$output" == "-o szo:p:q::r::wx:y:: -l switch,zwitch,option:,param:,query::,random::,wei-rd1,wei-rd2,wei--rd1:,wei--rd2:,_weird1::,_weird2::" ]
# }

# # TODO: check other test args, e.g. [VALUE...] ones
# # TODO: check what happens to unrecognised args
# # TODO: check what happens when incorrect argument counts are applied
