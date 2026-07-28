#!/usr/bin/env bash
#
# Verify that git submodules are pinned to the same commit a given branch in
# their upstream repository currently points to.
#
# Configuration is provided through the INPUT_SUBMODULES environment variable
# in one of two formats:
#
#   Line based (one submodule per line):
#     <path> = <repo-url>@<branch>
#     <path> = @<branch>            # repo url taken from .gitmodules
#
#   JSON array:
#     [{"path":"vendor/x","repo":"https://...","branch":"production"}, ...]
#
# Exit code is non-zero when any submodule is out of sync (or, with
# INPUT_FAIL_FAST=true, on the first mismatch).

set -euo pipefail

INPUT_SUBMODULES=${INPUT_SUBMODULES:-}
INPUT_FAIL_FAST=${INPUT_FAIL_FAST:-false}

if [[ -z "${INPUT_SUBMODULES//[[:space:]]/}" ]]; then
  echo "::error::No submodules configured. Set the 'submodules' input." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse configuration into three parallel arrays: paths, repos, branches.
# ---------------------------------------------------------------------------
paths=()
repos=()
branches=()

parse_json() {
  # Requires the JSON parsing helper. GitHub runners ship with jq.
  if ! command -v jq >/dev/null 2>&1; then
    echo "::error::jq is required to parse JSON 'submodules' input but was not found." >&2
    exit 1
  fi

  local count
  count=$(jq 'length' <<<"$INPUT_SUBMODULES")

  local i path repo branch
  for ((i = 0; i < count; i++)); do
    path=$(jq -r ".[$i].path // empty" <<<"$INPUT_SUBMODULES")
    repo=$(jq -r ".[$i].repo // \"\"" <<<"$INPUT_SUBMODULES")
    branch=$(jq -r ".[$i].branch // empty" <<<"$INPUT_SUBMODULES")

    if [[ -z "$path" || -z "$branch" ]]; then
      echo "::error::Every JSON entry needs a 'path' and a 'branch'." >&2
      exit 1
    fi

    paths+=("$path")
    repos+=("$repo")
    branches+=("$branch")
  done
}

parse_lines() {
  local line path rest repo branch
  while IFS= read -r line; do
    # Strip comments and surrounding whitespace, skip empty lines.
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -z "$line" ]] && continue

    if [[ "$line" != *"="* ]]; then
      echo "::error::Invalid submodule entry '$line'. Expected '<path> = <repo>@<branch>'." >&2
      exit 1
    fi

    path=${line%%=*}
    rest=${line#*=}

    # Trim whitespace around each side.
    path=${path#"${path%%[![:space:]]*}"}; path=${path%"${path##*[![:space:]]}"}
    rest=${rest#"${rest%%[![:space:]]*}"}; rest=${rest%"${rest##*[![:space:]]}"}

    if [[ "$rest" != *"@"* ]]; then
      echo "::error::Invalid submodule entry '$line'. Missing '@<branch>'." >&2
      exit 1
    fi

    # Split on the LAST '@' so URLs containing '@' still work.
    repo=${rest%@*}
    branch=${rest##*@}
    repo=${repo#"${repo%%[![:space:]]*}"}; repo=${repo%"${repo##*[![:space:]]}"}
    branch=${branch#"${branch%%[![:space:]]*}"}; branch=${branch%"${branch##*[![:space:]]}"}

    if [[ -z "$path" || -z "$branch" ]]; then
      echo "::error::Invalid submodule entry '$line'. Need a path and a branch." >&2
      exit 1
    fi

    paths+=("$path")
    repos+=("$repo")
    branches+=("$branch")
  done <<<"$INPUT_SUBMODULES"
}

trimmed=${INPUT_SUBMODULES#"${INPUT_SUBMODULES%%[![:space:]]*}"}
if [[ "$trimmed" == "["* ]]; then
  parse_json
else
  parse_lines
fi

if [[ ${#paths[@]} -eq 0 ]]; then
  echo "::error::No submodules could be parsed from the 'submodules' input." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Check each submodule.
# ---------------------------------------------------------------------------
mismatched=()
matched=()
had_error=0

# Resolve a submodule's upstream URL from .gitmodules when none was supplied.
url_from_gitmodules() {
  local target="$1" key section configured
  [[ -f .gitmodules ]] || return 1
  while read -r key configured; do
    if [[ "$configured" == "$target" ]]; then
      section=${key%.path}
      git config --file .gitmodules --get "${section}.url"
      return 0
    fi
  done < <(git config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)
  return 1
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
  fi
}

summary "## Submodule pinning check"
summary ""
summary "| Submodule | Branch | Pinned | Upstream | Status |"
summary "| --- | --- | --- | --- | --- |"

for i in "${!paths[@]}"; do
  path=${paths[$i]}
  repo=${repos[$i]}
  branch=${branches[$i]}

  echo "::group::Checking $path against ${branch}"

  # Resolve the repo URL from .gitmodules if it was not provided.
  if [[ -z "$repo" ]]; then
    if ! repo=$(url_from_gitmodules "$path"); then
      echo "::error::No repo URL given for '$path' and it is not found in .gitmodules." >&2
      had_error=1
      summary "| \`$path\` | \`$branch\` | - | - | :boom: no repo url |"
      echo "::endgroup::"
      [[ "$INPUT_FAIL_FAST" == "true" ]] && break || continue
    fi
  fi

  # Read the commit the submodule is pinned to from the current tree.
  if ! ls_tree=$(git ls-tree HEAD -- "$path") || [[ -z "$ls_tree" ]]; then
    echo "::error::'$path' is not present in the current commit." >&2
    had_error=1
    summary "| \`$path\` | \`$branch\` | - | - | :boom: not found |"
    echo "::endgroup::"
    [[ "$INPUT_FAIL_FAST" == "true" ]] && break || continue
  fi

  read -r object_mode object_type pinned_commit _ <<<"$ls_tree"
  if [[ "$object_mode" != "160000" || "$object_type" != "commit" ]]; then
    echo "::error::'$path' is not a git submodule (mode=$object_mode type=$object_type)." >&2
    had_error=1
    summary "| \`$path\` | \`$branch\` | - | - | :boom: not a submodule |"
    echo "::endgroup::"
    [[ "$INPUT_FAIL_FAST" == "true" ]] && break || continue
  fi

  # Fetch the current commit of the branch in the upstream repository.
  if ! remote_ref=$(git ls-remote --exit-code "$repo" "refs/heads/$branch" 2>/dev/null); then
    echo "::error::Branch '$branch' not found in '$repo'." >&2
    had_error=1
    summary "| \`$path\` | \`$branch\` | \`${pinned_commit:0:12}\` | - | :boom: branch missing |"
    echo "::endgroup::"
    [[ "$INPUT_FAIL_FAST" == "true" ]] && break || continue
  fi
  upstream_commit=${remote_ref%%[[:space:]]*}

  echo "Repository:       $repo"
  echo "Branch:           $branch"
  echo "Pinned commit:    $pinned_commit"
  echo "Upstream commit:  $upstream_commit"

  if [[ "$pinned_commit" == "$upstream_commit" ]]; then
    echo "::notice::'$path' matches '$branch' at $pinned_commit."
    matched+=("$path")
    summary "| \`$path\` | \`$branch\` | \`${pinned_commit:0:12}\` | \`${upstream_commit:0:12}\` | :white_check_mark: match |"
  else
    echo "::error::'$path' is pinned to $pinned_commit but '$branch' is at $upstream_commit." >&2
    mismatched+=("$path")
    summary "| \`$path\` | \`$branch\` | \`${pinned_commit:0:12}\` | \`${upstream_commit:0:12}\` | :x: mismatch |"
    [[ "$INPUT_FAIL_FAST" == "true" ]] && { echo "::endgroup::"; break; }
  fi

  echo "::endgroup::"
done

# ---------------------------------------------------------------------------
# Emit outputs.
# ---------------------------------------------------------------------------
json_array() {
  local out="[" first=1 item
  for item in "$@"; do
    [[ $first -eq 0 ]] && out+=","
    out+="\"$item\""
    first=0
  done
  out+="]"
  printf '%s' "$out"
}

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "mismatched=$(json_array "${mismatched[@]+"${mismatched[@]}"}")"
    echo "matched=$(json_array "${matched[@]+"${matched[@]}"}")"
  } >>"$GITHUB_OUTPUT"
fi

if [[ ${#mismatched[@]} -gt 0 || $had_error -ne 0 ]]; then
  echo "::error::Submodule pinning check failed for: ${mismatched[*]+"${mismatched[*]}"}" >&2
  exit 1
fi

echo "All submodules are pinned to their configured upstream branches."
