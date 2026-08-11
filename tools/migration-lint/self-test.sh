#!/usr/bin/env bash
# Self-test for migration-lint: proves the linter still detects what it exists to
# detect, and — just as important — that it stays quiet about the things it must
# not report.
#
# A linter that silently stops linting is worse than no linter, because INV-11 is
# then believed to be enforced when it is not.
set -uo pipefail
cd "$(dirname "$0")/../.."

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

fail=0
expect_rule() {
  if ! grep -q "$1" "$OUT"; then
    echo "FAIL: expected rule '$1' was not reported"
    fail=1
  fi
}

refute_mention() {
  if grep -q "$1" "$OUT"; then
    echo "FAIL: '$1' was reported but should not have been ($2)"
    fail=1
  fi
}

ruby tools/migration-lint/lint.rb --app=tools/migration-lint/fixtures/bad-app > "$OUT" 2>&1
status=$?

if [ "$status" -eq 0 ]; then
  echo "FAIL: linter exited 0 on a known-bad fixture"
  fail=1
fi

expect_rule "destructive-ddl"
expect_rule "not-null-without-default"
expect_rule "blocking-index"
expect_rule "missing-tenant-column"
expect_rule "missing-tenant-index"
expect_rule "missing-rls"

# False positives are the failure mode that gets a linter switched off, so the
# fixture also contains a correct table and a rollback method, and both must be
# reported on by nothing at all.
refute_mention "good_table" "it is a correctly written tenant table"
refute_mention ":23" "the drop_table inside def down is rollback code, not a forward migration"

if [ "$fail" -eq 0 ]; then
  echo "migration-lint self-test: OK (6 rules fired; correct table and rollback stayed quiet)"
else
  cat "$OUT"
fi
exit $fail
