import toml
import argparse
import os
import re
import sys
import subprocess
from packaging import version
from packaging.specifiers import SpecifierSet

import logging
# uncomment to get debug
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s: %(message)s')


def to_pep440(loose_constraint):
    logging.debug(f"to_pep440({loose_constraint})")

    match = re.match(r"\^(\d+)(?:\.(\d+))?(?:\.(\d+))?", loose_constraint)
    if not match:
        return loose_constraint

    major, minor, patch = match.groups()

    if major == "0":
        if minor is None:
          return "<1.0.0"
        elif patch is None:
            return f">=0.{minor}.0,<0.{int(minor) + 1}.0"
        else:
            return f">=0.{minor}.{patch},<0.{int(minor) + 1}.0"
    else:
      if minor is None:
        return f">={major}.0.0,<{int(major) + 1}.0.0"
      elif patch is None:
        return f">={major}.{minor}.0,<{int(major) + 1}.0.0"
      else:
        return f">={major}.{minor}.{patch},<{int(major) + 1}.0.0"

def get_constraint(pyproject_path):
    logging.debug(f"get_constraint({pyproject_path}")
    try:
        with open(pyproject_path, "r") as f:
            pyproject = toml.load(f)
    except FileNotFoundError:
        logging.error(f"pyproject.toml not found at {pyproject_path}")
        exit(1)
    except toml.TomlDecodeError as e:
        logging.error(f"Invalid pyproject.toml: {e}")
        exit(1)

    dependencies = pyproject["tool"]["poetry"]["dependencies"]
    if "python" in dependencies:
        return dependencies["python"]
    else:
        return None
    # except KeyError as e:
    #     if not (e.args[0] == "dependencies" and "tool" in pyproject and "poetry" in pyproject["tool"]):
    #         logging.error(f"Invalid pyproject.toml: Missing key {e}")
    #         exit(1)

def current_is_good(constraint_spec):
    # check for the current running python
    VERSION_REGEX = re.compile(
        version.VERSION_PATTERN, re.VERBOSE | re.IGNORECASE
    )
    logging.debug(f"current python={sys.version}")
    match = VERSION_REGEX.search(sys.version)
    if match:
        ver = version.parse(match.group(0))
        if ver in constraint_spec:
            return match.group(0)
    return None

def ensure_pyenv_installed():
    """Ensure pyenv is installed and return the path to the executable"""
    # Check if pyenv is in PATH first
    if check_command_exists("pyenv"):
        logging.debug("Using system pyenv at " + subprocess.check_output(["which", "pyenv"]).decode().strip())
        return "pyenv"

    # Check if pyenv exists at the default location
    pyenv_bin = os.path.expanduser("~/.pyenv/bin/pyenv")
    if os.path.isfile(pyenv_bin) and os.access(pyenv_bin, os.X_OK):
        logging.debug(f"Found pyenv at {pyenv_bin}")
        return pyenv_bin

    # Install pyenv
    logging.debug("Installing pyenv...")
    try:
        subprocess.run("curl -s https://pyenv.run | bash", shell=True, check=True)

        # Verify installation succeeded
        pyenv_bin = os.path.expanduser("~/.pyenv/bin/pyenv")
        if os.path.isfile(pyenv_bin) and os.access(pyenv_bin, os.X_OK):
            logging.debug(f"Successfully installed pyenv at {pyenv_bin}")
            return pyenv_bin
        else:
            logging.error("pyenv installation failed")
            return None
    except subprocess.CalledProcessError as e:
        logging.error(f"Failed to install pyenv: {e}")
        return None

def check_command_exists(cmd):
    """Check if a command exists and is executable"""
    return subprocess.run(f"command -v {cmd}", shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode == 0

def get_available_python_versions(pyenv_bin):
    """Get list of Python versions available for installation through pyenv"""
    logging.debug("Getting list of available Python versions from pyenv")
    try:
        output = subprocess.check_output([pyenv_bin, "install", "--list"], text=True)
        versions = []

        # Parse output and extract version numbers
        for line in output.splitlines():
            line = line.strip()
            # Look for standard versions like 3.8.0, 3.9.1, etc.
            match = re.match(r'^(\d+\.\d+\.\d+)$', line)
            if match:
                versions.append(match.group(1))

        logging.debug(f"Found {len(versions)} available Python versions")
        return versions
    except subprocess.CalledProcessError as e:
        logging.error(f"Failed to get available Python versions: {e}")
        return []

def find_best_version_match(constraint_spec, available_versions):
    """Find the best matching Python version from available versions"""
    logging.debug(f"Finding best match for {constraint_spec} from {len(available_versions)} versions")

    # Check for exact version constraints first
    exact_version = None
    for spec in constraint_spec:
        if spec.operator == "==":
            exact_version = str(spec.version)
            logging.debug(f"Found exact version constraint: {exact_version}")
            break

    # If we have an exact constraint, look for that specific version
    if exact_version:
        if exact_version in available_versions:
            logging.debug(f"Found exact match for {exact_version}")
            return exact_version

    # Otherwise, find all compatible versions
    compatible_versions = []
    for ver_str in available_versions:
        try:
            ver = version.parse(ver_str)
            if ver in constraint_spec:
                compatible_versions.append((ver, ver_str))
        except:
            continue

    if compatible_versions:
        # Sort by version, get the highest compatible version
        compatible_versions.sort(key=lambda v: v[0], reverse=True)
        highest_version = compatible_versions[0][1]
        logging.debug(f"Highest compatible version: {highest_version}")
        return highest_version

    # If we found no compatible versions but have an exact constraint,
    # return that so it can be attempted to install
    if exact_version:
        logging.debug(f"No compatible versions found, but returning exact constraint: {exact_version}")
        return exact_version

    logging.debug("No compatible versions found")
    return None

def find_matching(constraint_spec):
    logging.debug(f"find_matching({constraint_spec})")
    FILE_VERSION_REGEX = re.compile(
        r"python(" + version.VERSION_PATTERN + r")", re.VERBOSE | re.IGNORECASE
    )

    # Try to find matching local Python versions first
    matching_versions = []
    try:
        for filename in os.listdir("/usr/bin"):
            match = FILE_VERSION_REGEX.search(filename)
            if match:
                ver = version.parse(match.group(1))
                if ver in constraint_spec:
                    matching_versions.append((ver, match.group(0)))
    except (FileNotFoundError, PermissionError) as e:
        logging.warning(f"Error accessing /usr/bin: {e}")

    if matching_versions:
        highest_version, highest_version_str = max(matching_versions, key=lambda item: item[0])
        logging.debug(f"Found locally installed version: {highest_version}")
        return f"/usr/bin/{highest_version_str}"

    # No matching local versions, try pyenv
    # First ensure pyenv is installed
    pyenv_bin = ensure_pyenv_installed()
    if not pyenv_bin:
        logging.error("Failed to install or locate pyenv")
        return None

    # Get available versions and find best match
    available_versions = get_available_python_versions(pyenv_bin)
    best_match = find_best_version_match(constraint_spec, available_versions)

    if best_match:
        # Install the version
        logging.debug(f"Installing Python {best_match} using pyenv")
        try:
            subprocess.run([pyenv_bin, "install", "-s", best_match], check=True)

            # Get the full path to the Python executable
            python_path = subprocess.check_output(
                [pyenv_bin, "prefix", best_match], text=True
            ).strip() + "/bin/python"

            logging.debug(f"Successfully installed Python at {python_path}")
            return python_path
        except subprocess.CalledProcessError as e:
            logging.error(f"Failed to install Python {best_match}: {e}")

    # No matching version found
    return None

def main():
    logging.debug("matching-python.py")
    parser = argparse.ArgumentParser(description="Find a matching Python interpreter.")
    parser.add_argument('--pyproject', type=str, required=True, help="Path to the pyproject.toml file.")
    args = parser.parse_args()
    logging.debug(f"with args {args}")

    # get the constraint, if any
    constraint = get_constraint(args.pyproject)
    if constraint:
        # convert the constraint into something that can be compared
        pep440_constraint = to_pep440(constraint)
        constraint_spec = SpecifierSet(pep440_constraint)

        # use the system one first, if it matches
        current_version = current_is_good(constraint_spec)
        if current_version:
            logging.debug("current version is good")
            # Return just the version number for poetry to use
            print(f"python{current_version}")
            exit(0)

        # system one is no good so search for one or install with pyenv
        matching = find_matching(constraint_spec)
        if matching:
            logging.debug(f"-> {matching}")
            # Return the full path to the Python executable
            print(matching)
            exit(0)
        else:
            logging.error(f"No matching Python version found for: {constraint}, interpreted as {pep440_constraint}")
            exit(1)
    else:
        exit(0)

if __name__ == "__main__":
    main()
