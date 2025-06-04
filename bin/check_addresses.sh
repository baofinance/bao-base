#!/usr/bin/env bash

# Usage: ./compare-all-contracts.sh network1.json network2.json [network3.json ...]
# Example: ./compare-all-contracts.sh mainnet.json goerli.json polygon.json

if [[ "$#" -lt 2 ]]; then
  echo "Usage: $0 network1.json network2.json [network3.json ...]"
  exit 1
fi

# Create temporary file to store all contract names
TEMP_FILE=$(mktemp)
trap 'rm -f "${TEMP_FILE}"' EXIT

# Function to check if files exist
check_file() {
  if [[ ! -f "$1" ]]; then
    echo "Error: $1 does not exist"
    exit 1
  fi
}

# Check all files
for NETWORK in "$@"; do
  check_file "${NETWORK}"
done

# Extract all unique contract names across all networks
for NETWORK in "$@"; do
  jq -r 'keys[]' "${NETWORK}" >>"${TEMP_FILE}"
done

# Get unique sorted contract names (the superset)
ALL_CONTRACTS=$(sort -u "${TEMP_FILE}")

# Print header
echo "Contract availability across networks:"
echo "--------------------------------------"
printf "%-30s" "CONTRACT NAME"
for NETWORK in "$@"; do
  NETWORK_NAME=$(basename "${NETWORK}" .json)
  printf "%-20s" "${NETWORK_NAME}"
done
echo ""

# Print divider
printf "%-30s" "------------------------------"
for NETWORK in "$@"; do
  printf "%-20s" "-------------------"
done
echo ""

# For each contract in the superset, check each network
for CONTRACT in ${ALL_CONTRACTS}; do
  printf "%-30s" "${CONTRACT}"

  for NETWORK in "$@"; do
    NETWORK_NAME=$(basename "${NETWORK}" .json)

    # Check if contract exists in this network
    if jq -e ".[\"${CONTRACT}\"]" "${NETWORK}" >/dev/null 2>&1; then
      ADDRESS=$(jq -r ".[\"${CONTRACT}\"].address" "${NETWORK}")
      SHORT_ADDR="${ADDRESS:0:8}...${ADDRESS: -6}"
      printf "%-20s" "${SHORT_ADDR}"
    else
      printf "%-20s" "MISSING"
    fi
  done
  echo ""
done

echo ""
echo "Detailed missing contracts per network:"
echo "--------------------------------------"

# For each network, list missing contracts
for NETWORK in "$@"; do
  NETWORK_NAME=$(basename "${NETWORK}" .json)
  echo "Contracts missing in ${NETWORK_NAME}:"

  MISSING_COUNT=0
  for CONTRACT in ${ALL_CONTRACTS}; do
    if ! jq -e ".[\"${CONTRACT}\"]" "${NETWORK}" >/dev/null 2>&1; then
      echo "  - ${CONTRACT}"
      MISSING_COUNT=$((MISSING_COUNT + 1))
    fi
  done

  if [[ "${MISSING_COUNT}" -eq 0 ]]; then
    echo "  (None)"
  fi
  echo ""
done
