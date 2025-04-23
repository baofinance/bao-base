#!/usr/bin/env bash
#
# Cross-platform utilities for BAO scripts
# This file contains functions to handle platform-specific operations
#

# Detect OS and set environment variables
detect_platform() {
  # Platform detection - set OS variables
  export BAO_BASE_OS="unknown"
  export BAO_BASE_OS_SUBTYPE="unknown"
  export BAO_BASE_OS_VERSION="unknown"

  # Windows detection
  if [[ "$(uname)" == "MINGW"* || "$(uname)" == "MSYS"* || "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]]; then
    BAO_BASE_OS="windows"
    # Get Windows version
    if command -v powershell.exe &>/dev/null; then
      BAO_BASE_OS_SUBTYPE="powershell"
      BAO_BASE_OS_VERSION=$(powershell.exe -Command "[System.Environment]::OSVersion.Version.ToString()" | tr -d '\r')
    elif command -v systeminfo &>/dev/null; then
      BAO_BASE_OS_SUBTYPE="cmd"
      BAO_BASE_OS_VERSION=$(systeminfo | grep "OS Version:" | sed 's/.*: *//;s/\r//')
    fi
  # macOS detection
  elif [[ "$(uname)" == "Darwin" ]]; then
    BAO_BASE_OS="macos"
    if command -v sw_vers &>/dev/null; then
      BAO_BASE_OS_SUBTYPE="darwin"
      BAO_BASE_OS_VERSION=$(sw_vers -productVersion) # e.g. "10.15.7"
    fi
  # Linux detection
  elif [[ "$(uname)" == "Linux" ]]; then
    BAO_BASE_OS="linux"
    # Try to get distribution info
    if [[ -f /etc/os-release ]]; then
      BAO_BASE_OS_SUBTYPE=$(
        source /etc/os-release >/dev/null 2>&1
        echo "${ID,,}"
      ) # e.g. "ubuntu" "debian", "centos", "fedora"
      BAO_BASE_OS_VERSION=$(
        source /etc/os-release >/dev/null 2>&1
        echo "${VERSION_ID}"
      ) # e.g. "20.04", "11", "8"
    # Fallbacks if os-release isn't available
    elif command -v lsb_release &>/dev/null; then
      BAO_BASE_OS_SUBTYPE=$(lsb_release -si | tr '[:upper:]' '[:lower:]') # e.g. "ubuntu", "debian"
      BAO_BASE_OS_VERSION=$(lsb_release -sr)                              # e.g. "20.04", "11"
    elif [[ -f /etc/lsb-release ]]; then
      source /etc/lsb-release
      BAO_BASE_OS_SUBTYPE="${DISTRIB_ID,,}"    # e.g. "ubuntu", "debian"
      BAO_BASE_OS_VERSION="${DISTRIB_RELEASE}" # e.g. "20.04", "11"
    elif [[ -f /etc/debian_version ]]; then
      BAO_BASE_OS_SUBTYPE="debian"
    elif [[ -f /etc/redhat-release ]]; then
      BAO_BASE_OS_SUBTYPE=$(cat /etc/redhat-release | cut -d ' ' -f 1 | tr '[:upper:]' '[:lower:]') # e.g. "centos", "fedora"
      BAO_BASE_OS_VERSION=$(cat /etc/redhat-release | grep -oP '[0-9]+\.[0-9]+' | head -n 1)        # e.g. "8", "11"
    fi
  else
    BAO_BASE_OS="unknown"
  fi
}

# Create a temporary file in a platform-appropriate way
create_temp_file() {
  local prefix="${1:-temp}"
  if [[ "$BAO_BASE_OS" == "windows" ]]; then
    mktemp -t "${prefix}.XXXXXXXX"
  else
    mktemp
  fi
}

# Create a temporary directory in a platform-appropriate way
create_temp_dir() {
  local prefix="${1:-tempdir}"
  if [[ "$BAO_BASE_OS" == "windows" ]]; then
    mktemp -d -t "${prefix}.XXXXXXXX"
  else
    mktemp -d
  fi
}

# Calculate hash of a file consistently across platforms
calculate_hash() {
  local file="$1"
  local hash=""

  # Handle different OS hashing methods
  if [[ "${BAO_BASE_OS}" == "windows" ]]; then
    # Create a temporary file with normalized line endings
    debug "Running on Windows, converting CRLF to LF for consistent hashing"
    local temp_file
    temp_file=$(create_temp_file "hash")

    # Convert CRLF to LF
    sed 's/\r$//' "$file" >"$temp_file" 2>/dev/null

    # Generate hash
    if command -v certUtil &>/dev/null; then
      # Using certUtil if available
      local temp_output
      temp_output=$(create_temp_file "hashoutput")
      certUtil -hashfile "$temp_file" SHA256 >"$temp_output" 2>/dev/null
      hash=$(grep -v "hash" "$temp_output" | head -1 | tr -d " \t\r\n" || echo "")
      rm -f "$temp_output"
    elif command -v powershell.exe &>/dev/null; then
      # Try PowerShell as alternative
      local temp_output
      temp_output=$(create_temp_file "hashoutput")
      powershell.exe -Command "Get-FileHash -Algorithm SHA256 -Path '$temp_file' | Select-Object -ExpandProperty Hash" >"$temp_output" 2>/dev/null
      hash=$(cat "$temp_output" | tr -d '\r\n ' | tr '[:upper:]' '[:lower:]' || echo "")
      rm -f "$temp_output"
    else
      # Fallback to timestamp for Windows without proper hash tool
      hash=$(date +%s)
    fi
    rm -f "$temp_file"
  elif [[ "$BAO_BASE_OS" == "macos" ]]; then
    hash=$(shasum -a 256 "$file" | cut -d' ' -f1)
  elif [[ "$BAO_BASE_OS" == "linux" ]]; then
    hash=$(sha256sum "$file" | cut -d' ' -f1)
  else
    # Fallback with no hash - just return a timestamp to force regeneration
    debug "Unknown OS, using timestamp as hash"
    hash=$(date +%s)
  fi

  # Validate the hash format - should be 64 hex chars
  if ! [[ $hash =~ ^[0-9a-f]{64}$ ]]; then
    debug "Invalid hash format generated: '$hash', using timestamp instead"
    hash=$(date +%s)
  fi

  echo "$hash"
}

# Capture command output to prevent it from showing up in file outputs
# Usage: capture_output "command args" [show_on_error]
capture_output() {
  local cmd="$1"
  local show_on_error="${2:-true}"
  local result=0

  if [[ "$BAO_BASE_OS" == "windows" ]]; then
    local temp_output
    temp_output=$(create_temp_file "cmdoutput")
    eval "$cmd" >"$temp_output" 2>&1 || {
      result=$?
      if [[ "$show_on_error" == "true" ]]; then
        cat "$temp_output" >&2
      fi
      rm -f "$temp_output"
      return $result
    }
    rm -f "$temp_output"
  else
    eval "$cmd" || {
      result=$?
      return $result
    }
  fi

  return 0
}

uv_exe_name() {
  if [[ "$BAO_BASE_OS" == "windows" ]]; then
    echo "uv.exe"
  else
    echo "uv"
  fi
}

python_exe_in_env() {
  if [[ "$BAO_BASE_OS" == "windows" ]]; then
    echo "Scripts/python.exe"
  else
    echo "bin/python"
  fi
}

activate_script_in_env() {
  if [[ "$BAO_BASE_OS" == "windows" ]]; then
    echo "Scripts/activate"
  else
    echo "bin/activate"
  fi
}

# Make a file executable if needed and possible
make_executable() {
  local file="$1"

  if [[ "$BAO_BASE_OS" != "windows" && -f "$file" && ! -x "$file" ]]; then
    chmod +x "$file" || return 1
  fi

  return 0
}

# Export all functions so they're available to scripts that source this file
export -f detect_platform
export -f create_temp_file
export -f create_temp_dir
export -f calculate_hash
export -f capture_output
export -f make_executable
export -f uv_exe_name
export -f python_exe_in_env
export -f activate_script_in_env
