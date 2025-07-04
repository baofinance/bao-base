#!/usr/bin/env bash
set -euo pipefail
shopt -s extdebug

args=("$@") # reset the global args array for other scripts to use
# empty the default args array
set --

# shellcheck disable=SC1090,SC1091,SC2154
# . "${BAO_BASE_BIN_DIR}/run/logging"
# shellcheck disable=SC1090,SC1091,SC2154
. "${BAO_BASE_BIN_DIR}/run/environment"
# shellcheck disable=SC1090,SC1091,SC2154
. "${BAO_BASE_BIN_DIR}/run/transacting"
# shellcheck disable=SC1090,SC1091,SC2154
. "${BAO_BASE_BIN_DIR}/run/blockchain"
# shellcheck disable=SC1090,SC1091,SC2154
. "${BAO_BASE_BIN_DIR}/run/recording"

debug "deploy.sh: ${args[*]}"

# set the global variables needed for transacting/recording etc
# default to environment
PRIVATE_KEY=$(lookup_environment PRIVATE_KEY)
sensitive "${PRIVATE_KEY}" "private-key"
PUBLIC_KEY=$(public_from_private "${PRIVATE_KEY}")
ETHERSCAN_API_KEY=$(lookup_environment ETHERSCAN_API_KEY)
sensitive "${ETHERSCAN_API_KEY}" "etherscan-api-key"

# only allow this to be command line as it's dangerous
RPC_URL="local"
VERIFY="--verify"
BROADCAST=""
LOCAL="remote"
PUBLIC_KEY=""

myargs=("${args[@]}") # make a copy of args
debug "  args: ${args[*]}"
debug "myargs: ${myargs[*]}"
args=()

IMPERSONATE=""
while [[ ${#myargs[@]} -gt 0 ]]; do
  case "${myargs[0]}" in
    --as)
      IMPERSONATE="${myargs[1]}"
      myargs=("${myargs[@]:2}") # shift 2
      ;;
    --anvil)
      log "--rpc-local anvil is the saame as -rpc-url local, but using a test private key"
      PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
      PUBLIC_KEY="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
      RPC_URL="local"
      CHAIN_ID=1                # this is used for address lookup
      myargs=("${myargs[@]:1}") # shift 1
      ;;
    --rpc-url)
      RPC_URL="${myargs[1]}"
      myargs=("${myargs[@]:2}") # shift 2
      ;;
    --no-verify)
      VERIFY=""
      myargs=("${myargs[@]:1}") # shift 1
      ;;
    --broadcast)
      debug "setting BROADCAST"
      # shellcheck disable=SC2034
      BROADCAST="--broadcast"
      myargs=("${myargs[@]:1}") # shift 1
      ;;
    -h | --help)
      echo "Usage: ${0} [--rpc-url <url>] [--no-verify] [--broadcast] <script> [<args>...]"
      echo "  --rpc-url <url>   Specify the RPC URL to use (default: anvil)"
      echo "                    \"anvil\" is the same as -rpc-url local, but using a test private key"
      echo "  --no-verify       Skip verification of contracts on Etherscan, default is to verify on non-local RPC URLs"
      echo "  --broadcast       Broadcast transactions (default is no broadcasting, i.e. dry-run)"
      echo "  <script>          The script to run after setting up the environment"
      echo "  <args>...        Additional arguments to pass to the script"
      exit 0
      ;;
    *)
      args+=("${myargs[0]}")
      myargs=("${myargs[@]:1}") # shift 1
      ;;
  esac
done
debug "args: ${args[*]}"

# determine if we're running locally or not
if [[ "${RPC_URL}" == "local" || "${RPC_URL}" == *"localhost"* ]]; then
  LOCAL="local"
fi

# get the chain_id
CHAIN_ID=${CHAIN_ID:-$(chain_id)} || error "Failed to get chain ID from RPC URL: ${RPC_URL}"

log "transacting on${LOCAL:+ ${LOCAL}} chain ${CHAIN_ID}${CHAIN_NAME:+ (${CHAIN_NAME})}" # lint-bash disable=command-substitution
log "using wallet with public key $(ens_from_public "${PUBLIC_KEY}")"                    # lint-bash disable=command-substitution

OVERRIDE_RECORDING_NAME=$(find ./deploy -name "*_latest.log" -type f -printf "%T+ %p\n" | sort | head -n 1 | awk '{print $2}')

# IMPERSONATE_ADDRESS=""
# if [[ -n "$IMPERSONATE" ]]; then
#   IMPERSONATE_ADDRESS=$(resolve_array address "$IMPERSONATE")
#   log "Impersonating account: $IMPERSONATE ($IMPERSONATE_ADDRESS)"
#   trace cast rpc anvil_setBalance "$IMPERSONATE_ADDRESS" $(cast to-hex 27542757796200000000) >/dev/null # give them 27.5 ETH so they can pay gas
#   trace cast rpc anvil_impersonateAccount "$IMPERSONATE_ADDRESS"
# fi

log "${args[*]}"
# "${args[@]} --from $IMPERSONATE_ADDRESS --unlocked"
# trace cast rpc anvil_autoImpersonateAccount true

local raw_args=()
raw_args=$(resolve_array address "${args[@]}") || error "failed to resolve_array address $*"
local resolved_args=()
mapfile -t resolved_args <<<"$raw_args" || error "failed to resolve_array ${args[*]}"

# log "${resolved_args[*]}"
trace "${resolved_args[@]}" --rpc-url "${RPC_URL}" || error "failed to run script ${args[*]}"

# if [[ -n "$IMPERSONATE" ]]; then
#   trace cast rpc anvil_stopImpersonatingAccount "$IMPERSONATE_ADDRESS"
# fi
