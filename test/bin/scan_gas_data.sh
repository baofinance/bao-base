#!/usr/bin/env bash

# Scan a directory for gas data files following the conventions:
# - Old/New/Expected triples: gas_old*.txt, gas_new*.txt, gas_expected*.txt
# - Diff/Expected pairs:      gas_diff*.txt, gas_expected*.txt
#
# Output:
# - For each valid old/new/expected group, print three absolute paths separated by newlines,
#   followed by a blank line separator, then the expected file path on a fourth line (for clarity).
# - For each valid diff/expected pair, print the diff path, a blank line, then the expected path.
# - Errors are written to stderr for any mismatches: missing counterparts, mixed patterns, duplicates.
#
# Usage:
#   ./scan_gas_data.sh [DATA_DIR]
#
# If DATA_DIR is omitted, defaults to the repository's bin/test data directory.

# Don't exit on first error; keep counting and report at the end
set -uo pipefail

DATA_DIR=${1:-"$(cd "$(dirname "$0")" && pwd)/data"}

if [[ ! -d "$DATA_DIR" ]]; then
  echo "error: data directory not found: $DATA_DIR" >&2
  exit 1
fi

# Normalize to absolute path
DATA_DIR=$(cd "$DATA_DIR" && pwd)

shopt -s nullglob

declare -A seen_expected
declare -A used_files

errors=0
expected_count=0

abspath() {
  local p="$1"
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd)
  else
    local d
    d=$(cd "$(dirname "$p")" && pwd)
    echo "$d/$(basename "$p")"
  fi
}

# Helper to get the stem after the prefix and before .txt
stem_after() {
  local prefix="$1" file="$2"
  local base
  base=$(basename -- "$file")
  echo "${base#${prefix}}" | sed 's/\.txt$//'
}

# Normalize empty stems to a placeholder to avoid bad array subscripts with set -u
normalize_stem() {
  local s="$1"
  if [[ -z "$s" ]]; then
    echo "_"
  else
    echo "$s"
  fi
}

echo "# Scanning: $DATA_DIR" >&2

# Color setup (enable if stdout or stderr is a TTY)
if [[ -t 1 || -t 2 ]]; then
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  BLUE="\033[34m"
  BOLD="\033[1m"
  RESET="\033[0m"
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  BOLD=""
  RESET=""
fi

# Index files by stem for quick lookups
declare -A expect_map diff_map old_map new_map

for exp in "$DATA_DIR"/gas_expected*.txt; do
  [[ -e "$exp" ]] || continue
  stem=$(normalize_stem "$(stem_after "gas_expected" "$exp")")
  expect_map["$stem"]=$(abspath "$exp")
done
for diff in "$DATA_DIR"/gas_diff*.txt; do
  [[ -e "$diff" ]] || continue
  stem=$(normalize_stem "$(stem_after "gas_diff" "$diff")")
  diff_map["$stem"]=$(abspath "$diff")
done
for old in "$DATA_DIR"/gas_old*.txt; do
  [[ -e "$old" ]] || continue
  stem=$(normalize_stem "$(stem_after "gas_old" "$old")")
  old_map["$stem"]=$(abspath "$old")
done
for new in "$DATA_DIR"/gas_new*.txt; do
  [[ -e "$new" ]] || continue
  stem=$(normalize_stem "$(stem_after "gas_new" "$new")")
  new_map["$stem"]=$(abspath "$new")
done

# 1) Drive matching from expected files
for stem in "${!expect_map[@]}"; do
  exp_abs=${expect_map[$stem]}
  diff_abs=${diff_map[$stem]:-}
  old_abs=${old_map[$stem]:-}
  new_abs=${new_map[$stem]:-}
  ((expected_count++))

  if [[ -n "$diff_abs" && (-n "$old_abs" || -n "$new_abs") ]]; then
    # Error header for this expected
    echo -e "${RED}${BOLD}=== expected: ${exp_abs} ===${RESET}"
    # Limit file paths to basenames in error message
    diff_base=$(basename -- "$diff_abs")
    old_base="${old_abs:+$(basename -- "$old_abs")}"
    new_base="${new_abs:+$(basename -- "$new_abs")}"
    echo "error: both diff and old/new present for stem '$stem' ($diff_base${old_abs:+, $old_base}${new_abs:+, $new_base})" >&2
    ((errors++))
    continue
  fi

  if [[ -n "$diff_abs" ]]; then
    # OK header for diff+expected
    echo -e "${GREEN}${BOLD}=== expected: ${exp_abs} [diff] ===${RESET}"
    # Pair: diff, blank, expected
    printf "%s\n\n%s\n" "$diff_abs" "$exp_abs"
    used_files["$diff_abs"]=1
    used_files["$exp_abs"]=1
    continue
  fi

  # Expect old/new
  if [[ -z "$old_abs" && -z "$new_abs" ]]; then
    echo -e "${RED}${BOLD}=== expected: ${exp_abs} ===${RESET}"
    echo "error: expected exists but neither diff nor old/new present for stem '$stem' ($(basename -- "$exp_abs"))" >&2
    ((errors++))
    continue
  fi
  if [[ -z "$old_abs" ]]; then
    echo -e "${RED}${BOLD}=== expected: ${exp_abs} ===${RESET}"
    echo "error: missing old file for stem '$stem' (expected gas_old${stem}.txt)" >&2
    ((errors++))
    continue
  fi
  if [[ -z "$new_abs" ]]; then
    echo -e "${RED}${BOLD}=== expected: ${exp_abs} ===${RESET}"
    echo "error: missing new file for stem '$stem' (expected gas_new${stem}.txt)" >&2
    ((errors++))
    continue
  fi

  # OK header for old/new+expected
  echo -e "${GREEN}${BOLD}=== expected: ${exp_abs} [old/new] ===${RESET}"
  # Triplet: old, new, blank, expected
  printf "%s\n%s\n\n%s\n" "$old_abs" "$new_abs" "$exp_abs"
  used_files["$old_abs"]=1
  used_files["$new_abs"]=1
  used_files["$exp_abs"]=1
done

# 2) Errors for items without expected
for stem in "${!diff_map[@]}"; do
  if [[ -z "${expect_map[$stem]+x}" ]]; then
    diff_base=$(basename -- "${diff_map[$stem]}")
    echo "error: diff without expected for stem '$stem' ($diff_base)" >&2
    ((errors++))
  fi
done

# Collate stems from old/new without expected, emit one error per stem
declare -A seen_missing_expected
for stem in "${!old_map[@]}"; do
  if [[ -z "${expect_map[$stem]+x}" ]]; then
    seen_missing_expected["$stem"]=1
  fi
done
for stem in "${!new_map[@]}"; do
  if [[ -z "${expect_map[$stem]+x}" ]]; then
    seen_missing_expected["$stem"]=1
  fi
done
for stem in "${!seen_missing_expected[@]}"; do
  echo "error: old/new present without expected for stem '$stem'" >&2
  ((errors++))
done

# 3) Detect duplicate content among gas_old*.txt files
declare -A hash_to_files
for f in "$DATA_DIR"/gas_old*.txt; do
  [[ -e "$f" ]] || continue
  # Compute a stable hash of file contents
  if command -v sha256sum >/dev/null 2>&1; then
    h=$(sha256sum "$f" | awk '{print $1}')
  else
    # Fallback to md5sum if sha256sum isn't available
    h=$(md5sum "$f" | awk '{print $1}')
  fi
  f_abs=$(abspath "$f")
  if [[ -n "${hash_to_files[$h]:-}" ]]; then
    hash_to_files[$h]="${hash_to_files[$h]} $f_abs"
  else
    hash_to_files[$h]="$f_abs"
  fi
done

for h in "${!hash_to_files[@]}"; do
  IFS=' ' read -r -a files <<<"${hash_to_files[$h]}"
  if ((${#files[@]} > 1)); then
    # Print a red header and the error with the list of duplicate files
    echo -e "${RED}${BOLD}=== duplicate old files [same content] ===${RESET}"
    # Show only basenames for duplicates
    basenames=()
    for fp in "${files[@]}"; do
      basenames+=("$(basename -- "$fp")")
    done
    echo "error: duplicate gas_old*.txt files share identical content: ${basenames[*]}" >&2
    ((errors++))
  fi
done

# Single-line colored summary to stderr
if ((errors > 0)); then
  SUMMARY_HDR="${RED}${BOLD}=== Summary ===${RESET}"
  ERR_COLOR="$RED"
else
  SUMMARY_HDR="${GREEN}${BOLD}=== Summary ===${RESET}"
  ERR_COLOR="$GREEN"
fi
echo
echo -e "${SUMMARY_HDR} expected: ${BLUE}${expected_count}${RESET}, errors: ${ERR_COLOR}${errors}${RESET}" >&2
echo

if ((errors > 0)); then
  exit 2
else
  exit 0
fi
