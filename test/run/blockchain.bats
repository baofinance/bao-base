#!/usr/bin/env bats

setup() {
  BAO_BASE_BIN_DIR="./bin"
  BAO_BASE_SCRIPT_DIR="./script"
  BAO_BASE_VERBOSITY=4
  DEBUG=-vvvv
  # LOGGING_FILE_DESCRIPTOR=3
  export json_recording_file=""
  export json_recording_latest_file=""
  source ./bin/deploy.sh "BATS" --rpc-url local:test
  export json_recording_directory="$(mktemp -d)"
}

run_check() {
  local expect_status="$1"
  local expect="$2"
  shift 2
  run "$@"
  echo "status=$status"
  echo "output=$output"
  echo "expect=$expect"
  [ "$status" -eq "$expect_status" ]
  [ "$output" == "$expect" ]
}

@test "can access bcinfo using simple json paths" {
  set -e

  # good lookup
  run_check 0 "0xFC69e0a5823E2AfCBEb8a35d33588360F1496a00" network_query "baomultisig.address"

  # bad lookup
  run_check 0 "" network_query "bao.ddress"

  # longer lookup
  run_check 0 "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84" network_query "steth.address"
  run_check 0 "stETH" network_query "steth.symbol"
  run_check 0 "0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8" network_query "steth.priceFeed.usd.address"
  run_check 0 "0x86392dC19c0b719886221c78AB11eb8Cf5c52812" network_query "steth.priceFeed.eth.address"

}

@test "can write to a deploy file" {
  set -e

  # store
  record "0xFC69e0a5823E2AfCBEb8a35d33588360F1496a00" "owner.address"
  status=$?
  expect=$(
    cat <<'EOF'
{
  "owner": {
    "address": "0xFC69e0a5823E2AfCBEb8a35d33588360F1496a00"
  }
}
EOF
  )
  output=$(cat "$json_recording_directory/mainnet-BATS_latest.log")
  echo "output=$output."
  echo "expect=$expect."
  [ "$output" == "$expect" ]
  [ "$status" -eq 0 ]

  # query
  run_check 0 "0xFC69e0a5823E2AfCBEb8a35d33588360F1496a00" query "owner.address"

}
