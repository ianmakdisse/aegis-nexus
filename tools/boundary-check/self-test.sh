#!/usr/bin/env bash
# Self-test for boundary-check: proves the checker still detects the violations
# it exists to detect. A checker that silently stops checking is worse than none,
# because ADR-001's core assumption is that this tool works.
set -uo pipefail
cd "$(dirname "$0")/../.."

fail=0
expect_rule() {
  if ! grep -q "$1" /tmp/bc-out.txt; then
    echo "FAIL: expected rule '$1' was not reported"
    fail=1
  fi
}

ruby tools/boundary-check/check.rb --app=tools/boundary-check/fixtures/bad-app > /tmp/bc-out.txt 2>&1
status=$?

if [ "$status" -eq 0 ]; then
  echo "FAIL: checker exited 0 on a known-bad fixture"
  fail=1
fi

expect_rule "cross-context-table"
expect_rule "private-access"
expect_rule "raw-publish"
expect_rule "undeclared-public"

if [ "$fail" -eq 0 ]; then
  echo "boundary-check self-test: OK (all 4 rules fired on the bad fixture)"
else
  cat /tmp/bc-out.txt
fi
exit $fail
