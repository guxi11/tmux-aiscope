#!/usr/bin/env bash
# Run all test files in this directory.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0 FAIL=0

for t in "$DIR"/test_*.sh; do
  name="${t##*/}"
  printf '\033[1m%s\033[0m\n' "$name"
  if bash "$t"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
  echo ""
done

total=$((PASS + FAIL))
if ((FAIL == 0)); then
  printf '\033[32mAll %d test files passed.\033[0m\n' "$total"
else
  printf '\033[31m%d/%d test files failed.\033[0m\n' "$FAIL" "$total"
  exit 1
fi
