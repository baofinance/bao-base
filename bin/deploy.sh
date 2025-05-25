#! /usr/bin/env bash
set -euo pipefail

export SCRIPT="$1"
shift

# # shellcheck disable=SC1090,SC1091,SC2154
# . "${BAO_BASE_BIN_DIR}/run/logging"
# shellcheck disable=SC1090,SC1091,SC2154
. "${BAO_BASE_BIN_DIR}/run/environment"
# shellcheck disable=SC1090,SC1091,SC2154
. "${BAO_BASE_BIN_DIR}/run/transacting"
# shellcheck disable=SC1090,SC1091,SC2154
. "${BAO_BASE_BIN_DIR}/run/blockchain"
# shellcheck disable=SC1090,SC1091,SC2154
. "${BAO_BASE_BIN_DIR}/run/recording"

debug "deploy.sh: $*"

# set the global variables needed for transacting/recording etc
# default to environment
PRIVATE_KEY=$(lookup_environment PRIVATE_KEY)
ETHERSCAN_API_KEY=$(lookup_environment ETHERSCAN_API_KEY)

# only allow this to be command line as it's dangerous
RPC_URL="local"
VERIFY="--verify"
BROADCAST=""
LOCAL="remote"
PUBLIC_KEY=""

declare -a unhandled_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
  --rpc-url)
    RPC_URL="$2"
    shift 2
    ;;
  --no-verify)
    VERIFY=""
    shift
    ;;
  --broadcast)
    debug "setting BROADCAST"
    # shellcheck disable=SC2034
    BROADCAST="--broadcast"
    shift
    ;;
  *)
    unhandled_args+=("$1")
    shift
    ;;
  esac
done

# determine if we're running locally or not
if [[ "${RPC_URL}" == "local" || "${RPC_URL}" == *"localhost"* ]]; then
  LOCAL="local"
  # shellcheck disable=SC2034
  VERIFY="" # can't verify locally (yet)
fi

# override the private key in certain circumstances
if [[ "${RPC_URL}" == "local:test" ]]; then
  PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  PUBLIC_KEY="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  RPC_URL="local"
else
  sensitive "${PRIVATE_KEY}" "private-key"
  PUBLIC_KEY=$(public_from_private "${PRIVATE_KEY}")
fi
sensitive "${ETHERSCAN_API_KEY}" "etherscan-api-key"

# get the chain_id
CHAIN_ID=$(chain_id)

log "transacting on${LOCAL:+ ${LOCAL}} chain ${CHAIN_ID}${CHAIN_NAME:+ (${CHAIN_NAME})}" # lint-bash disable=command-substitution
log "using wallet with public key $(ens_from_public "${PUBLIC_KEY}")"                    # lint-bash disable=command-substitution

if [[ "${SCRIPT}" != "BATS" ]]; then
  . "${SCRIPT}" "${unhandled_args[@]}"
# ^ look, there's a dot
fi
