#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
cd "$repository_root"

swift build -c release

release_bin_path="$(swift build -c release --show-bin-path)"
shopt -s nullglob
release_objects=("$release_bin_path"/AutoTableCharts.build/*.o)
shopt -u nullglob

if (( ${#release_objects[@]} == 0 )); then
  echo "Could not find release-library objects under $release_bin_path/AutoTableCharts.build." >&2
  exit 1
fi

release_module="$release_bin_path/Modules/AutoTableCharts.swiftmodule"
if [[ ! -f "$release_module" ]]; then
  echo "Could not find the release module at $release_module." >&2
  exit 1
fi

if ! release_symbols="$(nm "${release_objects[@]}" | swift demangle)"; then
  echo "Could not inspect release-library symbols." >&2
  exit 1
fi

if ! release_module_strings="$(strings "$release_module")"; then
  echo "Could not inspect release-module metadata." >&2
  exit 1
fi

test_hook_pattern='AutoChartAnalyzerTestHooks|inheritedScopeDepthForTesting|lineageDepthForTesting'
if grep -E "$test_hook_pattern" <<<"$release_symbols" \
  || grep -E "$test_hook_pattern" <<<"$release_module_strings"
then
  echo "Test hooks leaked into the release library or its module metadata." >&2
  exit 1
fi

echo "Release library and module metadata contain no test hooks."
