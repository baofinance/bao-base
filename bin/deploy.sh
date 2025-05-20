#! /usr/bin/env bash

RPC_URL="local"
NO_VERIFY=false

if [ -f .env ]; then
  # Fallback: source .env (assumes no spaces or export keyword)
  set -a
  . .env
  set +a
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
  --rpc-url)
    RPC_URL="$2"
    shift 2
    ;;
  --no-verify)
    NO_VERIFY=true
    shift
    ;;
  -*)
    echo "Unknown option: $1"
    exit 1
    ;;
  *) break ;;
  esac
done

if [[ "$RPC_URL" == "local:test" ]]; then
  PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  PUBLIC_KEY="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  RPC_URL="local"
fi
sensitive "$PRIVATE_KEY"

log "Deploying $* to $RPC_URL network with private key $PRIVATE_KEY"

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

deploy_contract() {
  trace "$*"
  local contract_path=$1
  shift
  local constructor_args=("$@")
  local contract_name=$(basename "$contract_path" | cut -d ':' -f 2)
  local output
  local address
  local tx_hash
  local block_number

  # Deploy the contract
  if [ ${#constructor_args[@]} -eq 0 ]; then
    output=$(forge create "$contract_path" \
      --rpc-url "$RPC_URL" \
      --private-key "$PRIVATE_KEY" \
      --etherscan-api-key "$ETHERSCAN_API_KEY" \
      --verify \
      --broadcast 2>&1)
  else
    output=$(forge create "$contract_path" \
      --rpc-url "$RPC_URL" \
      --private-key "$PRIVATE_KEY" \
      --etherscan-api-key "$ETHERSCAN_API_KEY" \
      --verify \
      --broadcast \
      --constructor-args "${constructor_args[@]}" 2>&1)
  fi

  # Extract address and transaction hash
  address=$(echo "$output" | awk '/Deployed to:/ {print $NF}')
  tx_hash=$(echo "$output" | awk '/Transaction hash:/ {print $NF}')

  if [[ -z "$address" || -z "$tx_hash" ]]; then
    echo "Error: Failed to deploy $contract_name. See logs for details."
    echo "$output" >>"$OUTPUT_FILE"
    exit 1
  fi

  # Get block number of deployment transaction
  block_number=$(cast tx $tx_hash --rpc-url $RPC_URL | awk '/blockNumber/ {print $2}')

  if [[ -z "$block_number" ]]; then
    echo "Error: Failed to retrieve block number for $contract_name deployment."
    exit 1
  fi

  # Append deployment to output file
  echo "Deployment contract >> $contract_name: $address (Block: $block_number)" >>"$OUTPUT_FILE"
  echo "$address $block_number"
  outdent
}

confirm_deployment() {
  local contract_name=$1
  local contract_address=$2
  local deployment_block=$3
  local retry_count=0
  local current_block

  echo "Confirming deployment of $contract_name at $contract_address (Block: $deployment_block)..."

  while true; do
    current_block=$(cast block latest --rpc-url $RPC_URL | awk '/number/ {print $2}')
    if [[ -n "$current_block" && "$current_block" -gt "$deployment_block" ]]; then
      echo "Contract $contract_name confirmed. Current block: $current_block"
      echo "Contract confirmed >> $contract_name: $contract_address (Confirmed in Block: $deployment_block)" >>"$OUTPUT_FILE"
      break
    fi
    if [[ $retry_count -ge $MAX_RETRIES ]]; then
      echo "Error: Contract $contract_name at $contract_address not confirmed after $MAX_RETRIES retries."
      exit 1
    fi
    echo "Waiting for contract $contract_name confirmation. Current block: $current_block. Retry $((retry_count + 1))/$MAX_RETRIES"
    sleep $RETRY_DELAY
    retry_count=$((retry_count + 1))
  done
}

send_transaction() {
  local target_address=$1
  local calldata=$2
  local contract_name=$3
  local output

  echo "Sending transaction to $contract_name:$target_address..."
  output=$(cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    "$target_address" \
    "$calldata" 2>&1)

  if [ $? -ne 0 ]; then
    echo "Error: Transaction to $contract_name:$target_address failed. See logs for details."
    echo "$output" >>"$OUTPUT_FILE"
    exit 1
  fi

  # Log the transaction details without the transaction hash
  echo "Transaction to $contract_name at $target_address >> calldata: $calldata" >>"$OUTPUT_FILE"
  echo "Transaction to $contract_name at $target_address succeeded."
}

deploy_contract "$@"
