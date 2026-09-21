#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
audit_script="$script_directory/verify-release-library.sh"
fixture_root="$(
  mktemp -d "${TMPDIR:-/tmp}/autotablecharts-release-layout-tests.XXXXXX"
)"
fake_bin="$fixture_root/fake-bin"
fixtures_root="$fixture_root/fixtures"

cleanup() {
  if [[ -d "$fixture_root" ]]; then
    rm -rf -- "$fixture_root"
  fi
}
trap cleanup EXIT

mkdir -p "$fake_bin" "$fixtures_root"

cat > "$fake_bin/swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  build)
    for argument in "$@"; do
      if [[ "$argument" == "--show-bin-path" ]]; then
        printf '%s\n' "$ATC_FIXTURE_BIN_PATH"
        break
      fi
    done
    ;;
  demangle)
    cat
    ;;
  *)
    echo "Unexpected fake swift invocation: $*" >&2
    exit 2
    ;;
esac
EOF

cat > "$fake_bin/nm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

for artifact in "$@"; do
  printf '%s:\n' "$artifact"
  cat "$artifact"
done
EOF

cat > "$fake_bin/strings" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-a" ]]; then
  shift
fi
for artifact in "$@"; do
  cat "$artifact"
done
EOF

chmod +x "$fake_bin/swift" "$fake_bin/nm" "$fake_bin/strings"

new_fixture() {
  fixture_bin_path="$fixtures_root/$1"
  mkdir -p "$fixture_bin_path"
}

add_current_object() {
  local target_name="$1"
  mkdir -p "$fixture_bin_path/$target_name.build"
  printf 'clean symbol for %s\n' "$target_name" \
    > "$fixture_bin_path/$target_name.build/$target_name.swift.o"
}

add_legacy_object() {
  local target_name="$1"
  printf 'clean symbol for %s\n' "$target_name" \
    > "$fixture_bin_path/$target_name.o"
}

add_current_module() {
  local module_name="$1"
  local module_path="$fixture_bin_path/Modules/$module_name.swiftmodule"
  mkdir -p "$module_path"
  printf 'clean module for %s\n' "$module_name" \
    > "$module_path/arm64-apple-macos.swiftmodule"
  printf 'clean interface for %s\n' "$module_name" \
    > "$module_path/arm64-apple-macos.swiftinterface"
}

add_legacy_module() {
  local module_name="$1"
  printf 'clean module for %s\n' "$module_name" \
    > "$fixture_bin_path/$module_name.swiftmodule"
}

run_audit() {
  PATH="$fake_bin:$PATH" \
    ATC_FIXTURE_BIN_PATH="$fixture_bin_path" \
    "$audit_script"
}

expect_success() {
  local fixture_name="$1"
  local output
  if ! output="$(run_audit 2>&1)"; then
    echo "Release-layout fixture $fixture_name unexpectedly failed:" >&2
    echo "$output" >&2
    exit 1
  fi
  if ! grep -Fq \
    'SwiftPM release library and module metadata contain no test hooks.' \
    <<< "$output"
  then
    echo "Release-layout fixture $fixture_name missed its success marker." >&2
    exit 1
  fi
}

expect_failure() {
  local fixture_name="$1"
  local expected_message="$2"
  local output
  if output="$(run_audit 2>&1)"; then
    echo "Release-layout fixture $fixture_name unexpectedly passed." >&2
    exit 1
  fi
  if ! grep -Fq "$expected_message" <<< "$output"; then
    echo "Release-layout fixture $fixture_name missed its diagnostic:" >&2
    echo "$output" >&2
    exit 1
  fi
}

new_fixture current
for target_name in AutoTableCharts AutoTableChartsUI; do
  add_current_object "$target_name"
  add_current_module "$target_name"
done
expect_success current

new_fixture legacy
for target_name in AutoTableCharts AutoTableChartsUI; do
  add_legacy_object "$target_name"
  add_legacy_module "$target_name"
done
expect_success legacy

new_fixture missing-object
add_current_object AutoTableCharts
for module_name in AutoTableCharts AutoTableChartsUI; do
  add_current_module "$module_name"
done
expect_failure \
  missing-object \
  'Could not find release-library objects for AutoTableChartsUI.'

new_fixture missing-module
for target_name in AutoTableCharts AutoTableChartsUI; do
  add_current_object "$target_name"
done
add_current_module AutoTableCharts
expect_failure \
  missing-module \
  'Could not find the release module for AutoTableChartsUI.'

new_fixture symbol-leak
for target_name in AutoTableCharts AutoTableChartsUI; do
  add_current_object "$target_name"
  add_current_module "$target_name"
done
printf 'ATC_TEST_HOOKS\n' \
  >> "$fixture_bin_path/AutoTableCharts.build/AutoTableCharts.swift.o"
expect_failure \
  symbol-leak \
  'Test hooks leaked into SwiftPM release library or its module metadata.'

new_fixture module-leak
for target_name in AutoTableCharts AutoTableChartsUI; do
  add_legacy_object "$target_name"
  add_legacy_module "$target_name"
done
printf 'sessionForTesting\n' >> "$fixture_bin_path/AutoTableChartsUI.swiftmodule"
expect_failure \
  module-leak \
  'Test hooks leaked into SwiftPM release library or its module metadata.'

echo "Verified current and legacy SwiftPM release-library artifact discovery."
