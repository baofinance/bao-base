import toml
import argparse
import os
import re
import sys
# https://pypi.org/project/packaging/
from packaging import version
from packaging.specifiers import SpecifierSet

import logging
# uncomment to get debug
# logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s: %(message)s')


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

def find_matching(constraint):
    logging.debug(f"find_matching({constraint})")
    FILE_VERSION_REGEX = re.compile(
        r"python(" + version.VERSION_PATTERN + r")", re.VERBOSE | re.IGNORECASE
    )
    VERSION_REGEX = re.compile(
        version.VERSION_PATTERN, re.VERBOSE | re.IGNORECASE
    )

    # check for the current running python first
    spec = SpecifierSet(constraint)
    logging.debug(f"current python={sys.version}")
    match = VERSION_REGEX.search(sys.version)
    if match:
        ver = version.parse(match.group(0))
        if ver in spec:
            return match.group(0)

    # current one no good, so scan known places for one
    matching_versions = []
    try:
        for filename in os.listdir("/usr/bin"):
            match = FILE_VERSION_REGEX.search(filename)
            if match:
                ver = version.parse(match.group(1))
                if ver in spec:
                    matching_versions.append((ver, match.group(0)))
    except FileNotFoundError:
        logging.warning("/usr/bin not found")
        return None
    except PermissionError:
        logging.warning("Permission denied accessing /usr/bin")
        return None

    if matching_versions:
        highest_version, highest_version_str = max(matching_versions, key=lambda item: item[0])
        return f"/usr/bin/{highest_version_str}"


def main():
    logging.debug("matching-python.py")
    parser = argparse.ArgumentParser(description="Find a matching Python interpreter.")
    parser.add_argument('--directory', type=str, default=".", help="The directory containing pyproject.toml (defaults to current directory).")
    args = parser.parse_args()
    logging.debug(f"with args {args}")

    constraint = get_constraint(os.path.join(args.directory, "pyproject.toml"))
    if constraint:
        pep440_constraint = to_pep440(constraint)
        matching = find_matching(pep440_constraint)
        if matching:
            logging.debug(f"-> {matching}")
            print(matching)
            exit(0)
        else:
            logging.error(f"No matching Python version found for: {constraint}, interpreted as {pep440_constraint}")
            exit(1)
    else:
        exit(0)

if __name__ == "__main__":
    main()
