#!/usr/bin/env bash
#
# Self-contained test harness for check-submodule-pins.sh.
# Creates a local "upstream" repo and a "consumer" repo with a submodule,
# then exercises match / mismatch / error scenarios.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$SCRIPT_DIR/check-submodule-pins.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

pass=0
fail=0

expect() {
  # expect <description> <expected-exit> <actual-exit>
  local desc=$1 want=$2 got=$3
  if [[ "$want" == "$got" ]]; then
    echo "  ok   - $desc (exit $got)"
    pass=$((pass + 1))
  else
    echo "  FAIL - $desc (expected exit $want, got $got)"
    fail=$((fail + 1))
  fi
}

# --- Build an upstream repo with a 'production' branch ----------------------
UPSTREAM="$WORK/upstream"
git init -q -b main "$UPSTREAM"
(
  cd "$UPSTREAM"
  echo "v1" >file.txt
  git add . && git commit -q -m "initial"
  git switch -q -c production
  echo "prod" >>file.txt
  git add . && git commit -q -m "production commit"
  git switch -q main
)
PROD_COMMIT=$(git -C "$UPSTREAM" rev-parse production)

# --- Build a consumer repo pinning the submodule to production --------------
CONSUMER="$WORK/consumer"
git init -q -b main "$CONSUMER"
(
  cd "$CONSUMER"
  echo "app" >app.txt
  git add . && git commit -q -m "init"
  git -c protocol.file.allow=always submodule add -q "$UPSTREAM" vendor/lib
  git -C vendor/lib checkout -q "$PROD_COMMIT"
  git add . && git commit -q -m "pin submodule to production"
)

cd "$CONSUMER"

echo "Test 1: matching pin (line format, url from .gitmodules)"
set +e
INPUT_SUBMODULES="vendor/lib = @production" bash "$CHECK" >/dev/null 2>&1
expect "match should pass" 0 $?
set -e

echo "Test 2: matching pin (explicit repo)"
set +e
INPUT_SUBMODULES="vendor/lib = $UPSTREAM@production" bash "$CHECK" >/dev/null 2>&1
expect "match with explicit repo should pass" 0 $?
set -e

echo "Test 3: matching pin (JSON format)"
set +e
INPUT_SUBMODULES="[{\"path\":\"vendor/lib\",\"branch\":\"production\"}]" bash "$CHECK" >/dev/null 2>&1
expect "match via JSON should pass" 0 $?
set -e

echo "Test 4: mismatched pin (checking against main)"
set +e
INPUT_SUBMODULES="vendor/lib = @main" bash "$CHECK" >/dev/null 2>&1
expect "mismatch should fail" 1 $?
set -e

echo "Test 5: nonexistent branch"
set +e
INPUT_SUBMODULES="vendor/lib = @nope" bash "$CHECK" >/dev/null 2>&1
expect "missing branch should fail" 1 $?
set -e

echo "Test 6: nonexistent submodule path"
set +e
INPUT_SUBMODULES="vendor/missing = $UPSTREAM@production" bash "$CHECK" >/dev/null 2>&1
expect "missing submodule should fail" 1 $?
set -e

echo "Test 7: empty input"
set +e
INPUT_SUBMODULES="   " bash "$CHECK" >/dev/null 2>&1
expect "empty input should fail" 1 $?
set -e

echo "Test 8: invalid line (no branch)"
set +e
INPUT_SUBMODULES="vendor/lib = $UPSTREAM" bash "$CHECK" >/dev/null 2>&1
expect "invalid line should fail" 1 $?
set -e

echo "Test 9: outputs are written"
set +e
out_file="$WORK/output.txt"
: >"$out_file"
INPUT_SUBMODULES="vendor/lib = @production" GITHUB_OUTPUT="$out_file" bash "$CHECK" >/dev/null 2>&1
set -e
if grep -q 'matched=\["vendor/lib"\]' "$out_file" && grep -q 'mismatched=\[\]' "$out_file"; then
  echo "  ok   - outputs contain expected matched/mismatched"
  pass=$((pass + 1))
else
  echo "  FAIL - outputs missing or wrong:"
  cat "$out_file"
  fail=$((fail + 1))
fi

echo
echo "Passed: $pass, Failed: $fail"
[[ $fail -eq 0 ]]
