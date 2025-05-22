#!/usr/bin/env bash
set -euo pipefail

dep_dir=$(dirname "$0")

# Cleanup function for temporary files
cleanup() {
  local exit_code=$?
  # Check if temp_dir exists and is not empty
  if [[ -n "${temp_dir:-}" && -d "${temp_dir}" ]]; then
    echo "Cleaning up temporary directory: ${temp_dir}"
    rm -rf "${temp_dir}"
  fi

  # Output error message if script failed
  if [[ ${exit_code} -ne 0 ]]; then
    echo "Error: Script exited with status ${exit_code}" >&2
  fi

  exit "${exit_code}"
}

# Trap signals for cleanup
trap cleanup EXIT INT TERM

foundry_version="stable"
os_version="ubuntu-latest" # TODO: read this from the BAO_BASE_OS_* variables
workflow="foundry"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
  --workflow | -w)
    workflow=$2
    shift 2
    ;;
  --foundry | -f)
    foundry_version=$2
    shift 2
    ;;
  --os | -o)
    os_version=$2
    shift 2
    ;;
  --help | -h)
    echo "Usage: $0 [--workflow <workflow>] [--foundry <version>] [--os <os_version>] [<args>]"
    echo " -w --workflow <workflow>   Specify the workflow to run (default: foundry)"
    echo " -f --foundry <version>     Specify the Foundry version (default: stable)"
    echo " -o --os <os_version>       Specify the OS version (default: ubuntu-latest)"
    echo " -h --help                  Show this help message"
    exit 0
    ;;
  *) break ;;
  esac
done

echo "Running CI for ${foundry_version} foundry on ${os_version}"

# shellcheck disable=SC2154
temp_dir="${BAO_BASE_TOOLS_DIR}/act-cache/$$"
mkdir -p "${temp_dir}"
echo "Created temporary directory: ${temp_dir}"

workflow_template_file="${dep_dir}/local_test_${workflow}.yml"
workflow_file="${temp_dir}/local_test_${workflow}_${os_version}_${foundry_version}.yml"
event_template_file="${dep_dir}/workflow_dispatch.json"
event_file="${temp_dir}/workflow_dispatch_${os_version}_${foundry_version}.json"

echo "replacing \$OS_VERSION with '${os_version}' and \$FOUNDY_VERSION with '${foundry_version}' in ${event_template_file}"
# shellcheck disable=SC2154 # we don't need to check if the variable is set
sed "s|\$OS_VERSION|${os_version}|g" "${event_template_file}" | sed "s|\$FOUNDRY_VERSION|${foundry_version}|g" >"${event_file}"

# shellcheck disable=SC2154
echo "replacing \$BAO_BASE_DIR with './${BAO_BASE_DIR}' in ${workflow_file}"
# shellcheck disable=SC2154 # we don't need to check if the variable is set
sed "s|\$BAO_BASE_DIR|./${BAO_BASE_DIR}|g" "${workflow_template_file}" >"${workflow_file}"

mutex_acquire "act"

# shellcheck disable=SC2154
if [[ ! -x "${BAO_BASE_TOOLS_DIR}/act/act" ]]; then
  info 0 "installing act..."
  mkdir -p "${BAO_BASE_TOOLS_DIR}/act"
  # shellcheck disable=SC2154
  if [[ "${BAO_BASE_OS}" == "linux" ]]; then
    curl https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b "${BAO_BASE_TOOLS_DIR}/act"
    if [[ ! -x "${BAO_BASE_TOOLS_DIR}/act/act" ]]; then
      echo "act installation failed"
      exit 1
    fi
  elif [[ "${BAO_BASE_OS}" == "macos" ]]; then
    brew install act
  else
    echo "operating system not supported yet"
  fi
fi

mutex_release "act"

echo act -P ubuntu-latest=-self-hosted -W "${workflow_file}" -e "${event_file}" "$@"
"${BAO_BASE_TOOLS_DIR}"/act/act -P ubuntu-latest=-self-hosted -W "${workflow_file}" -e "${event_file}" "$@"
