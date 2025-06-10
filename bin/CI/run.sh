#!/usr/bin/env bash
set -euo pipefail

dep_dir=$(dirname "${BASH_SOURCE[0]}")
debug "dep_dir=${dep_dir}"

# Cleanup function for temporary files
cleanup() {
  local exit_code=$?
  # Check if temp_dir exists and is not empty
  if [[ -n "${temp_dir:-}" && -d "${temp_dir}" ]]; then
    log "Cleaning up temporary directory: ${temp_dir}"
    rm -rf "${temp_dir}"
  fi
  mutex_release "act"
  mutex_release "act-submodule"

  # Output error message if script failed
  if [[ ${exit_code} -ne 0 ]]; then
    error "CI exited with status ${exit_code}" >&2
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

log "Running CI for ${foundry_version} foundry on ${os_version}"

# create a temporary directory to hold modified events and workflow files (this is not the temp directory act uses)
# shellcheck disable=SC2154
temp_dir="${BAO_BASE_TOOLS_DIR}/act-cache/$$"
mkdir -p "${temp_dir}"
log "Created temporary directory: ${temp_dir}"

workflow_template_file="${dep_dir}/local_test_${workflow}.yml"
workflow_file="${temp_dir}/local_test_${workflow}_${os_version}_${foundry_version}.yml"
event_template_file="${dep_dir}/workflow_dispatch.json"
event_file="${temp_dir}/workflow_dispatch_${os_version}_${foundry_version}.json"

# handle submodules - in submodules .git is a file, in the root, it is a directory
if [[ -f .git ]]; then
  mutex_acquire "act-submodule"
  rm ~/.cache/act/.git
  # get the root directory, basically 2 levels up
  parent_repo_root=$(git rev-parse --show-superproject-working-tree)
  # we know where the act cache directory is - and two levels up just happens to be somewhere we can access
  ln -s ${parent_repo_root}/.git ~/.cache/act/.git
fi

# hack the event file to hardcode the os_version and foundry_version to the values passed in (or defaulted)
log "replacing \$OS_VERSION with '${os_version}' and \$FOUNDY_VERSION with '${foundry_version}' in ${event_template_file} > ${event_file}"
# shellcheck disable=SC2154 # we don't need to check if the variable is set
sed "s|\$OS_VERSION|${os_version}|g" "${event_template_file}" | sed "s|\$FOUNDRY_VERSION|${foundry_version}|g" >"${event_file}"

# hack the workflow file to hardcode the correct directory
# shellcheck disable=SC2154
log "replacing \$BAO_BASE_DIR with './${BAO_BASE_DIR}' in ${workflow_template_file} > ${workflow_file}"
# shellcheck disable=SC2154 # we don't need to check if the variable is set
sed "s|\$BAO_BASE_DIR|./${BAO_BASE_DIR}|g" "${workflow_template_file}" >"${workflow_file}"

# stop multiple instances of this script installing act at the same time
mutex_acquire "act"

# shellcheck disable=SC2154
if [[ ! -x "${BAO_BASE_TOOLS_DIR}/act/act" ]]; then
  log "installing act..."
  mkdir -p "${BAO_BASE_TOOLS_DIR}/act"
  # shellcheck disable=SC2154
  if [[ "${BAO_BASE_OS}" == "linux" ]]; then
    curl https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b "${BAO_BASE_TOOLS_DIR}/act"
    if [[ ! -x "${BAO_BASE_TOOLS_DIR}/act/act" ]]; then
      error "act installation failed"
    fi
  elif [[ "${BAO_BASE_OS}" == "macos" ]]; then
    brew install act
  else
    error "operating system not supported yet"
  fi
fi

# let them go
mutex_release "act"

"${BAO_BASE_TOOLS_DIR}"/act/act -P ubuntu-latest=-self-hosted -W "${workflow_file}" -e "${event_file}" "$@" || error "CI run failed"
log "CI run succeeded"
mutex_release "act-submodule"
