#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
audit_script="$script_directory/verify-release-library.sh"
fixture_workspace="$(
  mktemp -d "${TMPDIR:-/tmp}/autotablecharts-release-layout-tests.XXXXXX"
)"
fake_bin="$fixture_workspace/fake-bin"
fixture_cases="$fixture_workspace/cases"

cleanup() {
  if [[ -d "$fixture_workspace" ]]; then
    rm -rf -- "$fixture_workspace"
  fi
}
trap cleanup EXIT

mkdir -p "$fake_bin" "$fixture_cases"

cat > "$fake_bin/swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  build)
    for argument in "$@"; do
      if [[ "$argument" == "--show-bin-path" ]]; then
        printf '%s\n' "$ATC_SWIFTPM_BIN_PATH"
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
  local fixture_path="$fixture_cases/$1"
  mkdir -p "$fixture_path"
  printf '%s\n' "$fixture_path"
}

add_swiftpm_current_object() {
  local fixture_path="$1"
  local target_name="$2"
  mkdir -p "$fixture_path/$target_name.build"
  printf 'clean symbol for %s\n' "$target_name" \
    > "$fixture_path/$target_name.build/$target_name.swift.o"
}

add_swiftpm_legacy_object() {
  local fixture_path="$1"
  local target_name="$2"
  printf 'clean symbol for %s\n' "$target_name" \
    > "$fixture_path/$target_name.o"
}

add_swiftpm_current_module() {
  local fixture_path="$1"
  local module_name="$2"
  local module_path="$fixture_path/Modules/$module_name.swiftmodule"
  mkdir -p "$module_path"
  printf 'clean module for %s\n' "$module_name" \
    > "$module_path/arm64-apple-macos.swiftmodule"
  printf 'clean interface for %s\n' "$module_name" \
    > "$module_path/arm64-apple-macos.swiftinterface"
}

add_swiftpm_legacy_module() {
  local fixture_path="$1"
  local module_name="$2"
  printf 'clean module for %s\n' "$module_name" \
    > "$fixture_path/$module_name.swiftmodule"
}

add_swiftpm_current_layout() {
  local fixture_path="$1"
  for target_name in AutoTableCharts AutoTableChartsUI; do
    add_swiftpm_current_object "$fixture_path" "$target_name"
    add_swiftpm_current_module "$fixture_path" "$target_name"
  done
}

add_swiftpm_legacy_layout() {
  local fixture_path="$1"
  for target_name in AutoTableCharts AutoTableChartsUI; do
    add_swiftpm_legacy_object "$fixture_path" "$target_name"
    add_swiftpm_legacy_module "$fixture_path" "$target_name"
  done
}

xcode_release_path() {
  printf '%s\n' "$1/Build/Products/Release-iphoneos"
}

add_xcode_object() {
  local derived_data_path="$1"
  local target_name="$2"
  local release_path
  release_path="$(xcode_release_path "$derived_data_path")"
  mkdir -p "$release_path"
  printf 'clean symbol for %s\n' "$target_name" \
    > "$release_path/$target_name.o"
}

add_xcode_module() {
  local derived_data_path="$1"
  local module_name="$2"
  local release_path
  release_path="$(xcode_release_path "$derived_data_path")"
  mkdir -p "$release_path/$module_name.swiftmodule"
  printf 'clean module for %s\n' "$module_name" \
    > "$release_path/$module_name.swiftmodule/arm64-apple-ios.swiftmodule"
}

add_xcode_layout() {
  local derived_data_path="$1"
  for target_name in AutoTableCharts AutoTableChartsUI; do
    add_xcode_object "$derived_data_path" "$target_name"
    add_xcode_module "$derived_data_path" "$target_name"
  done
}

run_audit() {
  local audit_mode="$1"
  local fixture_path="$2"
  case "$audit_mode" in
    swiftpm)
      PATH="$fake_bin:$PATH" \
        ATC_SWIFTPM_BIN_PATH="$fixture_path" \
        "$audit_script"
      ;;
    xcode)
      PATH="$fake_bin:$PATH" \
        "$audit_script" --xcode-derived-data "$fixture_path"
      ;;
    *)
      echo "Unknown release-layout audit mode: $audit_mode" >&2
      exit 2
      ;;
  esac
}

expect_success() {
  local fixture_name="$1"
  local audit_mode="$2"
  local fixture_path="$3"
  local expected_message="$4"
  local output
  if ! output="$(run_audit "$audit_mode" "$fixture_path" 2>&1)"; then
    echo "Release-layout fixture $fixture_name unexpectedly failed:" >&2
    echo "$output" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_message" <<< "$output"
  then
    echo "Release-layout fixture $fixture_name missed its success marker." >&2
    exit 1
  fi
}

expect_failure() {
  local fixture_name="$1"
  local audit_mode="$2"
  local fixture_path="$3"
  local expected_message="$4"
  local output
  if output="$(run_audit "$audit_mode" "$fixture_path" 2>&1)"; then
    echo "Release-layout fixture $fixture_name unexpectedly passed." >&2
    exit 1
  fi
  if ! grep -Fq "$expected_message" <<< "$output"; then
    echo "Release-layout fixture $fixture_name missed its diagnostic:" >&2
    echo "$output" >&2
    exit 1
  fi
}

swiftpm_success_message='SwiftPM release library and module metadata contain no test hooks.'
xcode_success_message='Xcode release library and module metadata contain no test hooks.'
leak_message='Test hooks leaked into SwiftPM release library or its module metadata.'
xcode_leak_message='Test hooks leaked into Xcode release library or its module metadata.'

fixture_path="$(new_fixture swiftpm-current)"
add_swiftpm_current_layout "$fixture_path"
expect_success swiftpm-current swiftpm "$fixture_path" "$swiftpm_success_message"

fixture_path="$(new_fixture swiftpm-legacy)"
add_swiftpm_legacy_layout "$fixture_path"
expect_success swiftpm-legacy swiftpm "$fixture_path" "$swiftpm_success_message"

fixture_path="$(new_fixture swiftpm-missing-object)"
add_swiftpm_current_object "$fixture_path" AutoTableCharts
for module_name in AutoTableCharts AutoTableChartsUI; do
  add_swiftpm_current_module "$fixture_path" "$module_name"
done
expect_failure \
  swiftpm-missing-object swiftpm "$fixture_path" \
  'Could not find release-library objects for AutoTableChartsUI.'

fixture_path="$(new_fixture swiftpm-missing-module)"
for target_name in AutoTableCharts AutoTableChartsUI; do
  add_swiftpm_current_object "$fixture_path" "$target_name"
done
add_swiftpm_current_module "$fixture_path" AutoTableCharts
expect_failure \
  swiftpm-missing-module swiftpm "$fixture_path" \
  'Could not find the release module for AutoTableChartsUI.'

fixture_path="$(new_fixture swiftpm-symbol-leak)"
add_swiftpm_current_layout "$fixture_path"
printf 'ATC_TEST_HOOKS\n' \
  >> "$fixture_path/AutoTableCharts.build/AutoTableCharts.swift.o"
expect_failure swiftpm-symbol-leak swiftpm "$fixture_path" "$leak_message"

fixture_path="$(new_fixture swiftpm-binary-module-leak)"
add_swiftpm_current_layout "$fixture_path"
printf 'sessionForTesting\n' \
  >> "$fixture_path/Modules/AutoTableChartsUI.swiftmodule/arm64-apple-macos.swiftmodule"
expect_failure swiftpm-binary-module-leak swiftpm "$fixture_path" "$leak_message"

fixture_path="$(new_fixture swiftpm-interface-leak)"
add_swiftpm_current_layout "$fixture_path"
printf 'sessionForTesting\n' \
  >> "$fixture_path/Modules/AutoTableChartsUI.swiftmodule/arm64-apple-macos.swiftinterface"
expect_failure swiftpm-interface-leak swiftpm "$fixture_path" "$leak_message"

fixture_path="$(new_fixture swiftpm-legacy-module-leak)"
add_swiftpm_legacy_layout "$fixture_path"
printf 'sessionForTesting\n' >> "$fixture_path/AutoTableChartsUI.swiftmodule"
expect_failure swiftpm-legacy-module-leak swiftpm "$fixture_path" "$leak_message"

fixture_path="$(new_fixture xcode-current)"
add_xcode_layout "$fixture_path"
expect_success xcode-current xcode "$fixture_path" "$xcode_success_message"

fixture_path="$(new_fixture xcode-missing-object)"
add_xcode_object "$fixture_path" AutoTableCharts
for module_name in AutoTableCharts AutoTableChartsUI; do
  add_xcode_module "$fixture_path" "$module_name"
done
expect_failure \
  xcode-missing-object xcode "$fixture_path" \
  'Could not find an Xcode Release AutoTableChartsUI.o under'

fixture_path="$(new_fixture xcode-missing-module)"
for target_name in AutoTableCharts AutoTableChartsUI; do
  add_xcode_object "$fixture_path" "$target_name"
done
add_xcode_module "$fixture_path" AutoTableCharts
expect_failure \
  xcode-missing-module xcode "$fixture_path" \
  'Could not find Xcode Release modules for AutoTableChartsUI under'

fixture_path="$(new_fixture xcode-symbol-leak)"
add_xcode_layout "$fixture_path"
xcode_release="$(xcode_release_path "$fixture_path")"
printf 'ATC_TEST_HOOKS\n' >> "$xcode_release/AutoTableCharts.o"
expect_failure xcode-symbol-leak xcode "$fixture_path" "$xcode_leak_message"

fixture_path="$(new_fixture xcode-module-leak)"
add_xcode_layout "$fixture_path"
xcode_release="$(xcode_release_path "$fixture_path")"
printf 'sessionForTesting\n' \
  >> "$xcode_release/AutoTableChartsUI.swiftmodule/arm64-apple-ios.swiftmodule"
expect_failure xcode-module-leak xcode "$fixture_path" "$xcode_leak_message"

echo "Verified SwiftPM and Xcode release-library artifact discovery."
