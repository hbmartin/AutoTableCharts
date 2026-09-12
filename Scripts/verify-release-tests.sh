#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
cd "$repository_root"

if (( $# != 1 )); then
  echo "Usage: $0 <with-hooks|without-hooks>" >&2
  exit 2
fi

case "$1" in
  with-hooks)
    swift_test_arguments=(-c release -Xswiftc -DATC_TEST_HOOKS)
    expected_state="executed"
    ;;
  without-hooks)
    swift_test_arguments=(-c release)
    expected_state="skipped"
    ;;
  *)
    echo "Usage: $0 <with-hooks|without-hooks>" >&2
    exit 2
    ;;
esac

hook_test_specifiers=()
while IFS= read -r test_specifier; do
  if [[ -n "$test_specifier" && "${test_specifier:0:1}" != "#" ]]; then
    hook_test_specifiers+=("$test_specifier")
  fi
done < "$script_directory/release-hook-tests.txt"

if (( ${#hook_test_specifiers[@]} == 0 )); then
  echo "The hook-dependent test manifest is empty." >&2
  exit 1
fi

swift_test_source_list="$(mktemp "${TMPDIR:-/tmp}/autotablecharts-swift-sources.XXXXXX")"
test_output=""
cleanup() {
  rm -f "$swift_test_source_list"
  if [[ -n "$test_output" ]]; then
    rm -f "$test_output"
  fi
}
trap cleanup EXIT

if ! find Tests/AutoTableChartsTests -type f -name '*.swift' -print0 \
  > "$swift_test_source_list"
then
  echo "Could not enumerate Swift test sources for the release audit." >&2
  exit 1
fi

swift_test_sources=()
while IFS= read -r -d '' swift_test_source; do
  swift_test_sources+=("$swift_test_source")
done < "$swift_test_source_list"

if (( ${#swift_test_sources[@]} == 0 )); then
  echo "No Swift test sources were found for the release audit." >&2
  exit 1
fi

if perl -0ne '
  $found ||= /#if ATC_TEST_HOOKS\s+\@Test/;
  END { exit($found ? 0 : 1) }
' "${swift_test_sources[@]}"
then
  echo "Hook-dependent tests must use a conditional trait, not a conditional @Test attribute." >&2
  exit 1
fi

manifest_count="${#hook_test_specifiers[@]}"

for test_specifier in "${hook_test_specifiers[@]}"; do
  test_name="${test_specifier##*/}"
  test_name="${test_name%%(*}"
  if HOOK_TEST_NAME="$test_name" perl -0ne '
    while (/(\@Test\b(?:(?!\@Test\b).)*?\bfunc\s+\Q$ENV{HOOK_TEST_NAME}\E\s*\([^)]*\)(?:(?!\@Test\b).)*?)(?=\@Test\b|\z)/sg) {
      $block = $1;
      $matches++;
      $guards++
        if $block =~ /\.disabled\(\s*if:\s*!testHooksAvailable,\s*testHooksUnavailable\s*\)/s;
      $bodies++
        if $block =~ /\bfunc\s+\Q$ENV{HOOK_TEST_NAME}\E\s*\([^)]*\).*?\{\s*#if\s+ATC_TEST_HOOKS\b/s;
    }
    END {
      exit 2 if ($matches || 0) != 1;
      exit 3 if ($guards || 0) != 1;
      exit 4 if ($bodies || 0) != 1;
    }
  ' "${swift_test_sources[@]}"
  then
    :
  else
    audit_status=$?
    case "$audit_status" in
      2) audit_problem="does not identify exactly one source test" ;;
      3) audit_problem="does not carry the required unavailable-hook guard" ;;
      4) audit_problem="does not wrap its body in #if ATC_TEST_HOOKS" ;;
      *) audit_problem="could not be audited" ;;
    esac
    echo "Hook-dependent test $test_specifier $audit_problem." >&2
    exit 1
  fi
done

read -r hook_guard_count hook_body_count < <(perl -0ne '
  while (/(\@Test\b(?:(?!\@Test\b).)*?\bfunc\s+[A-Za-z_][A-Za-z0-9_]*\s*\([^)]*\)(?:(?!\@Test\b).)*?)(?=\@Test\b|\z)/sg) {
    $block = $1;
    $guards++
      if $block =~ /\.disabled\(\s*if:\s*!testHooksAvailable,\s*testHooksUnavailable\s*\)/s;
    $bodies++ if $block =~ /^\s*#if\s+ATC_TEST_HOOKS\b/m;
  }
  END { print(($guards || 0) . " " . ($bodies || 0) . "\n") }
' "${swift_test_sources[@]}")

if [[ "$hook_guard_count" -ne "$manifest_count" \
  || "$hook_body_count" -ne "$manifest_count" ]]
then
  echo \
    "Hook-test manifest has $manifest_count entries, but found $hook_guard_count guarded tests and $hook_body_count hook-dependent test bodies." \
    >&2
  exit 1
fi

test_output="$(mktemp "${TMPDIR:-/tmp}/autotablecharts-release-tests.XXXXXX")"

if ! swift test "${swift_test_arguments[@]}" 2>&1 | tee "$test_output"; then
  echo "Release tests $1 failed." >&2
  exit 1
fi

skip_marker='[ATC_TEST_HOOKS unavailable]'
marker_count="$(grep -Fc "$skip_marker" "$test_output" || true)"
if [[ "$expected_state" == "skipped" ]]; then
  if [[ "$marker_count" -ne "${#hook_test_specifiers[@]}" ]]; then
    echo "Expected ${#hook_test_specifiers[@]} hook-dependent skips, found $marker_count." >&2
    exit 1
  fi
elif [[ "$marker_count" -ne 0 ]]; then
  echo "Hook-enabled release tests unexpectedly reported $marker_count unavailable-hook skips." >&2
  exit 1
fi

if ! test_listing="$(
  swift test "${swift_test_arguments[@]}" --skip-build list 2>&1
)"; then
  echo "Could not list release tests $1." >&2
  exit 1
fi

for test_specifier in "${hook_test_specifiers[@]}"; do
  listing_count="$(grep -Fxc "$test_specifier" <<<"$test_listing" || true)"
  if [[ "$listing_count" -ne 1 ]]; then
    echo "Expected one discovered test named $test_specifier, found $listing_count." >&2
    exit 1
  fi

  test_filter="${test_specifier//./\\.}"
  test_filter="${test_filter//(/\\(}"
  test_filter="${test_filter//)/\\)}"
  if ! swift test \
    "${swift_test_arguments[@]}" \
    --skip-build \
    --filter "$test_filter" \
    2>&1 | tee "$test_output"
  then
    echo "Hook-dependent test $test_specifier failed in $1 mode." >&2
    exit 1
  fi

  filtered_marker_count="$(grep -Fc "$skip_marker" "$test_output" || true)"
  if [[ "$expected_state" == "skipped" ]]; then
    if [[ "$filtered_marker_count" -ne 1 ]]; then
      echo "Expected $test_specifier to report one unavailable-hook skip." >&2
      exit 1
    fi
  elif [[ "$filtered_marker_count" -ne 0 ]] \
    || grep -Fq ' skipped:' "$test_output" \
    || grep -Fq 'No matching test cases were run' "$test_output"
  then
    echo "Expected $test_specifier to execute with hooks enabled." >&2
    exit 1
  fi
done

echo "Verified ${#hook_test_specifiers[@]} hook-dependent tests were $expected_state in $1 mode."
