#!/usr/bin/env bash
#
# Platform detection for bao-base scripts

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

first_free_fd() {
  local prev=2
  local this=3

  # Check if we're on Windows using Git Bash or WSL
  if [[ "$BAO_BASE_OS" == "windows" ]]; then
    # For Windows, just use a simple approach since file descriptor listing is limited
    # Start with FD 3 which is typically free
    for fd in {3..9}; do
      # Try to test if the FD is in use by attempting to redirect to it
      if ! ({ eval "exec ${fd}>&-"; } 2>/dev/null); then
        continue
      fi
      echo "$fd"
      return
    done
    # Default to 3 if we couldn't determine
    echo "3"
  else
    # Linux / macos implementation
    local fds
    fds=$(lsof -p $$ | awk '$4 ~ /^([0-9]+)[urw]*$/ {print +$4}' | sort -n)
    local fd
    while read -r fd; do
      this=$((prev + 1))
      if [ "${fd}" -gt "$this" ]; then
        echo "$this"
        return
      fi
      prev=$fd
    done <<<"${fds}"
    echo "$this"
  fi
}
export -f first_free_fd
