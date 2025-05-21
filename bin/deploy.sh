#! /usr/bin/env bash

. "$BAO_BASE_BIN_DIR/run/logging"
. "$BAO_BASE_BIN_DIR/run/environment"
. "$BAO_BASE_BIN_DIR/run/transacting"
. "$BAO_BASE_BIN_DIR/run/blockchain"
. "$BAO_BASE_BIN_DIR/run/recording"

debug "deploy.sh: $*"
SCRIPT="$1"
shift

# set the global variables needed for transacting/recording etc
# default to environment
PRIVATE_KEY=$(lookup_environment PRIVATE_KEY)
ETHERSCAN_API_KEY=$(lookup_environment ETHERSCAN_API_KEY)

# only allow this to be command line as it's dangerous
RPC_URL="local"
VERIFY="--verify"
BROADCAST=""
LOCAL=""
PUBLIC_KEY=""

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
    BROADCAST="--broadcast"
    shift
    ;;
  -*)
    echo "Unknown option: $1"
    exit 1
    ;;
  *) break ;;
  esac
done

# determine if we're running locally or not
if [[ "$RPC_URL" == "local" || "$RPC_URL" == *"localhost"* ]]; then
  LOCAL="local"
  VERIFY="" # can't verify locally (yet)
fi

# override the private key in certain circumstances
if [[ "$RPC_URL" == "local:test" ]]; then
  PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  PUBLIC_KEY="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  RPC_URL="local"
else
  sensitive "$PRIVATE_KEY" "private-key"
  PUBLIC_KEY=$(public_from_private $PRIVATE_KEY)
fi
sensitive "$ETHERSCAN_API_KEY" "etherscan-api-key"

# get the chain_id
CHAIN_ID=$(chain_id)

record_to "$SCRIPT"

log "transacting on${LOCAL:+ $LOCAL} chain $CHAIN_ID${CHAIN_NAME:+ ($CHAIN_NAME)}"
log "using wallet with public key $(ens_from_public $PUBLIC_KEY)"

###################################################################################################
# Phases
###################################################################################################

###################################################################################################
# deploy proxies
# - proxies are completely independent of each other
# - this gives us addresses so we can join the contracts up more easily
###################################################################################################

###################################################################################################
# deploy implementations, attach to proxies, perform transactions
# - this is the guts of the deployment
# - order of deployment/transaction is important and is left to the script to get it right
###################################################################################################

###################################################################################################
# verify
###################################################################################################

. "$SCRIPT" "$@"
