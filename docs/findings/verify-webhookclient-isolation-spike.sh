#!/usr/bin/env sh
# Verification test for TICKET-004 deliverable.
# Asserts the spike report exists and satisfies each acceptance criterion.
# Read-only: inspects only the report; does NOT touch src/WebhookClient.
#
# Usage: sh docs/findings/verify-webhookclient-isolation-spike.sh
# Exit 0 = all checks pass; non-zero = a check failed.

set -eu

REPORT="$(dirname "$0")/webhookclient-isolation-spike.md"
fail=0

check() {
  # check "<description>" "<grep -E pattern>"
  if grep -Eiq -- "$2" "$REPORT"; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"
    fail=1
  fi
}

# AC1: report exists and is non-empty
if [ -s "$REPORT" ]; then
  echo "PASS: report exists and is non-empty ($REPORT)"
else
  echo "FAIL: report missing or empty ($REPORT)"
  exit 1
fi

# AC2: classified as external-facing/false-positive, orphaned, or wiring-gap
check "AC2 classification present" "false[ -]?positive|orphaned|wiring[ -]?gap|external-facing"

# AC3: lists the HTTP endpoints exposed (or states none)
check "AC3 lists /webhook-received endpoint" "/webhook-received"
check "AC3 lists /check endpoint" "/check"

# AC4: keep/remove/wire recommendation
check "AC4 keep/remove/wire recommendation present" "Recommendation.*(KEEP|REMOVE|WIRE)|KEEP"

# AC4: references the WebhookClient unwired finding IDs
check "finding id cmph8qw0y005sqa16yhcf008y" "cmph8qw0y005sqa16yhcf008y"
check "finding id cmph8qw2a006oqa16ubf5ru3r" "cmph8qw2a006oqa16ubf5ru3r"
check "finding id cmph8qw0m005kqa16f8zurqiw" "cmph8qw0m005kqa16f8zurqiw"
check "finding id cmph8qw1c0062qa16jof36svh" "cmph8qw1c0062qa16jof36svh"
check "finding id cmph8qw1r006cqa16g860rvgq" "cmph8qw1r006cqa16g860rvgq"

if [ "$fail" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  echo "ONE OR MORE CHECKS FAILED"
  exit 1
fi
