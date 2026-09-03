#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
cd "$repository_root"

expected_skipped_tests=(
  asyncValidationPreservesCancellationForInvalidSpecifications
  cancellationBeforeKeyedMaterializationDoesNotReadRows
  childTaskStopsInheritingCompletedNestedCallbackScope
  completedCallbackScopesArePrunedBeforeLaterDelegation
  prepareCancellationTakesPriorityOverInvalidSpecification
  removeAllDoesNotFailConcurrentAnalyzeCallers
  removeAllRetriesUncancelledPreparedChartWaiters
  trimStopsInFlightWorkFromRepopulatingTheCache
)
skip_reason='Requires the ATC_TEST_HOOKS compilation condition;'
test_output="$(mktemp "${TMPDIR:-/tmp}/autotablecharts-release-tests.XXXXXX")"
trap 'rm -f "$test_output"' EXIT

if ! swift test -c release 2>&1 | tee "$test_output"; then
  echo "Release tests without test hooks failed." >&2
  exit 1
fi

for test_name in "${expected_skipped_tests[@]}"; do
  skip_count="$(grep -Fc "Test $test_name() skipped:" "$test_output" || true)"
  if [[ "$skip_count" -ne 1 ]]; then
    echo "Expected exactly one skip event for $test_name(), found $skip_count." >&2
    exit 1
  fi
done

actual_hook_skip_count="$(grep -Fc "$skip_reason" "$test_output" || true)"
expected_hook_skip_count="${#expected_skipped_tests[@]}"
if [[ "$actual_hook_skip_count" -ne "$expected_hook_skip_count" ]]; then
  echo "Expected $expected_hook_skip_count hook-dependent skips, found $actual_hook_skip_count." >&2
  exit 1
fi

echo "Verified all $expected_hook_skip_count hook-dependent tests were explicitly skipped."
