#!/usr/bin/env bash
# Verify that each submodule listed in .gitmodules.lock is pinned to the commit
# recorded there, that no extra keys are present, and that the working tree is clean.
# Aborts immediately on any mismatch.

set -euo pipefail

LOCK_FILE=".gitmodules.commitlock"
GITMODULES_FILE=".gitmodules"

if [[ ! -f "$LOCK_FILE" ]]; then
  echo "error: $LOCK_FILE not found" >&2
  exit 1
fi

if [[ ! -f "$GITMODULES_FILE" ]]; then
  echo "error: $GITMODULES_FILE not found" >&2
  exit 1
fi

# Confirm the lock file uses valid git-config syntax.
if ! git config --file "$LOCK_FILE" --name-only --list >/dev/null; then
  echo "error: $LOCK_FILE contains invalid git-config syntax" >&2
  exit 1
fi

mapfile -t commit_lines < <(
  git config --file "$LOCK_FILE" --get-regexp '^submodule\..*\.commit$'
)

if [[ ${#commit_lines[@]} -eq 0 ]]; then
  echo "error: $LOCK_FILE contains no submodule commits" >&2
  exit 1
fi

status=0

for line in "${commit_lines[@]}"; do
  key=${line%% *}  # submodule.<name>.commit
  value=${line#* } # 40-hex SHA (possibly whitespace-stripped already)
  name=${key#submodule.}
  name=${name%.commit}

  # Ensure no unexpected keys exist for this submodule.
  mapfile -t keys_for_sub < <(
    git config --file "$LOCK_FILE" --name-only --get-regexp "^submodule\.${name}\..*$"
  )
  for full_key in "${keys_for_sub[@]}"; do
    suffix=${full_key#submodule.${name}.}
    if [[ "$suffix" != "commit" && "$suffix" != "comment" ]]; then
      echo "error: $LOCK_FILE entry '${full_key}' is not allowed (only commit/comment permitted)" >&2
      status=1
      continue 2
    fi
  done

  if [[ ! "$value" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "error: submodule '$name' has invalid commit '$value'" >&2
    status=1
    continue
  fi

  if ! path=$(git config --file "$GITMODULES_FILE" "submodule.${name}.path"); then
    echo "error: .gitmodules missing path for submodule '$name'" >&2
    status=1
    continue
  fi

  if [[ ! -d "$path" ]]; then
    echo "error: submodule directory '$path' not found (run 'git submodule update --init -- \"$path\"')" >&2
    status=1
    continue
  fi

  if ! actual_commit=$(git -C "$path" rev-parse HEAD); then
    echo "error: unable to read HEAD for submodule '$name' at '$path'" >&2
    status=1
    continue
  fi

  if [[ "$actual_commit" != "$value" ]]; then
    echo "error: submodule '$name' mismatch:
  path:     $path
  expected: $value
  actual:   $actual_commit" >&2
    status=1
    continue
  fi

  if ! sub_status=$(git submodule status -- "$path"); then
    status=1
    continue
  fi
  if [[ ${sub_status:0:1} == "-" || ${sub_status:0:1} == "+" ]]; then
    echo "error: submodule '$name' at '$path' has local changes or is out of sync:
  $sub_status" >&2
    status=1
    continue
  fi

  comment=$(git config --file "$LOCK_FILE" "submodule.${name}.comment" 2>/dev/null || true)
  if [[ -n "$comment" ]]; then
    echo "$name: OK @ $value  # $comment"
  else
    echo "$name: OK @ $value"
  fi
done

exit "$status"
