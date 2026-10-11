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
  add_swiftpm_current_module_sidecars "$fixture_path" "$module_name"
}

add_swiftpm_current_module_sidecars() {
  local fixture_path="$1"
  local module_name="$2"
  local module_path="$fixture_path/Modules/$module_name.swiftmodule"
  mkdir -p "$module_path"
  printf 'clean documentation for %s\n' "$module_name" \
    > "$module_path/arm64-apple-macos.swiftdoc"
  printf 'clean ABI for %s\n' "$module_name" \
    > "$module_path/arm64-apple-macos.abi.json"
}

add_swiftpm_legacy_module() {
  local fixture_path="$1"
  local module_name="$2"
  printf 'clean module for %s\n' "$module_name" \
    > "$fixture_path/$module_name.swiftmodule"
  add_swiftpm_legacy_interfaces "$fixture_path" "$module_name"
  add_swiftpm_legacy_module_sidecars "$fixture_path" "$module_name"
}

add_swiftpm_legacy_interfaces() {
  local fixture_path="$1"
  local module_name="$2"
  printf 'clean interface for %s\n' "$module_name" \
    > "$fixture_path/$module_name.swiftinterface"
  printf 'clean private interface for %s\n' "$module_name" \
    > "$fixture_path/$module_name.private.swiftinterface"
  printf 'clean package interface for %s\n' "$module_name" \
    > "$fixture_path/$module_name.package.swiftinterface"
}

add_swiftpm_legacy_module_sidecars() {
  local fixture_path="$1"
  local module_name="$2"
  printf 'clean documentation for %s\n' "$module_name" \
    > "$fixture_path/$module_name.swiftdoc"
  printf 'clean ABI for %s\n' "$module_name" \
    > "$fixture_path/$module_name.abi.json"
}

add_swiftpm_legacy_interface() {
  local fixture_path="$1"
  local module_name="$2"
  add_swiftpm_legacy_interfaces "$fixture_path" "$module_name"
  add_swiftpm_legacy_module_sidecars "$fixture_path" "$module_name"
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

add_swiftpm_interface_layout() {
  local fixture_path="$1"
  for target_name in AutoTableCharts AutoTableChartsUI; do
    add_swiftpm_legacy_object "$fixture_path" "$target_name"
    add_swiftpm_legacy_interface "$fixture_path" "$target_name"
  done
}

add_swiftpm_mixed_layout() {
  local fixture_path="$1"
  add_swiftpm_current_layout "$fixture_path"
  for target_name in AutoTableCharts AutoTableChartsUI; do
    add_swiftpm_legacy_interfaces "$fixture_path/Modules" "$target_name"
    add_swiftpm_legacy_module_sidecars "$fixture_path/Modules" "$target_name"
  done
}

xcode_release_path() {
  printf '%s\n' "$1/Build/Products/${2:-Release-iphoneos}"
}

xcode_module_stem() {
  local release_path
  release_path="$(xcode_release_path "$1" "${3:-Release-iphoneos}")"
  if [[ "${4:-direct}" == framework ]]; then
    release_path="$release_path/PackageFrameworks/$2.framework/Modules"
  fi
  printf '%s\n' "$release_path/$2"
}

add_xcode_object() {
  local derived_data_path="$1"
  local target_name="$2"
  local release_path
  release_path="$(xcode_release_path "$derived_data_path" "${3:-Release-iphoneos}")"
  mkdir -p "$release_path"
  printf 'clean symbol for %s\n' "$target_name" \
    > "$release_path/$target_name.o"
}

add_xcode_module() {
  local derived_data_path="$1"
  local module_name="$2"
  local module_stem
  module_stem="$(
    xcode_module_stem "$derived_data_path" "$module_name" \
      "${3:-Release-iphoneos}" "${4:-direct}"
  )"
  mkdir -p "$module_stem.swiftmodule"
  printf 'clean module for %s\n' "$module_name" \
    > "$module_stem.swiftmodule/arm64-apple-ios.swiftmodule"
  printf 'clean interface for %s\n' "$module_name" \
    > "$module_stem.swiftmodule/arm64-apple-ios.swiftinterface"
  add_xcode_module_sidecars "$derived_data_path" "$module_name" \
    "${3:-Release-iphoneos}" "${4:-direct}"
}

add_xcode_module_sidecars() {
  local derived_data_path="$1"
  local module_name="$2"
  local module_stem
  module_stem="$(
    xcode_module_stem "$derived_data_path" "$module_name" \
      "${3:-Release-iphoneos}" "${4:-direct}"
  )"
  mkdir -p "$module_stem.swiftmodule"
  printf 'clean documentation for %s\n' "$module_name" \
    > "$module_stem.swiftmodule/arm64-apple-ios.swiftdoc"
  printf 'clean ABI for %s\n' "$module_name" \
    > "$module_stem.swiftmodule/arm64-apple-ios.abi.json"
}

add_xcode_interface() {
  local derived_data_path="$1"
  local module_name="$2"
  local module_stem
  module_stem="$(
    xcode_module_stem "$derived_data_path" "$module_name" \
      "${3:-Release-iphoneos}" "${4:-direct}"
  )"
  mkdir -p "$module_stem.swiftmodule"
  printf 'clean interface for %s\n' "$module_name" \
    > "$module_stem.swiftmodule/arm64-apple-ios.swiftinterface"
  add_xcode_module_sidecars "$derived_data_path" "$module_name" \
    "${3:-Release-iphoneos}" "${4:-direct}"
}

add_xcode_flat_interface() {
  local module_stem
  module_stem="$(
    xcode_module_stem "$1" "$2" "${3:-Release-iphoneos}" "${4:-direct}"
  )"
  mkdir -p "${module_stem%/*}"
  printf 'clean interface for %s\n' "$2" \
    > "$module_stem.${5:-swiftinterface}"
}

add_xcode_flat_sidecars() {
  local module_stem
  module_stem="$(
    xcode_module_stem "$1" "$2" "${3:-Release-iphoneos}" "${4:-direct}"
  )"
  mkdir -p "${module_stem%/*}"
  printf 'clean documentation for %s\n' "$2" > "$module_stem.swiftdoc"
  printf 'clean ABI for %s\n' "$2" > "$module_stem.abi.json"
}

add_xcode_layout() {
  local derived_data_path="$1"
  for target_name in AutoTableCharts AutoTableChartsUI; do
    add_xcode_object "$derived_data_path" "$target_name" "${2:-Release-iphoneos}"
    add_xcode_module "$derived_data_path" "$target_name" \
      "${2:-Release-iphoneos}" "${3:-direct}"
  done
}

add_xcode_interface_layout() {
  local derived_data_path="$1"
  for target_name in AutoTableCharts AutoTableChartsUI; do
    add_xcode_object "$derived_data_path" "$target_name" "${2:-Release-iphoneos}"
    add_xcode_interface "$derived_data_path" "$target_name" \
      "${2:-Release-iphoneos}" "${3:-direct}"
  done
}

add_xcode_flat_layout() {
  local derived_data_path="$1"
  for target_name in AutoTableCharts AutoTableChartsUI; do
    add_xcode_object "$derived_data_path" "$target_name" "${2:-Release-iphoneos}"
    add_xcode_flat_interface "$derived_data_path" "$target_name" \
      "${2:-Release-iphoneos}" "${3:-direct}" "${4:-swiftinterface}"
    add_xcode_flat_sidecars "$derived_data_path" "$target_name" \
      "${2:-Release-iphoneos}" "${3:-direct}"
  done
}

add_xcode_mixed_layout() {
  add_xcode_layout "$1"
  add_xcode_flat_layout "$1"
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
      return 2
      ;;
  esac
}

expect_success() {
  local fixture_name="$1"
  local audit_mode="$2"
  local fixture_path="$3"
  local expected_message="$4"
  local output
  local status
  if output="$(run_audit "$audit_mode" "$fixture_path" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    echo "Release-layout fixture $fixture_name unexpectedly failed:" >&2
    echo "$output" >&2
    exit "$status"
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
  local status
  if output="$(run_audit "$audit_mode" "$fixture_path" 2>&1)"; then
    echo "Release-layout fixture $fixture_name unexpectedly passed." >&2
    exit 1
  else
    status=$?
  fi
  if (( status != 1 )); then
    echo "Release-layout fixture $fixture_name could not run:" >&2
    echo "$output" >&2
    exit "$status"
  fi
  if ! grep -Fq "$expected_message" <<< "$output"; then
    echo "Release-layout fixture $fixture_name missed its diagnostic:" >&2
    echo "$output" >&2
    exit 1
  fi
}

expect_usage_failure() {
  local output
  local status
  if output="$("$audit_script" --invalid-argument 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if (( status != 2 )); then
    echo "Release audit usage fixture returned status $status instead of 2:" >&2
    echo "$output" >&2
    exit 1
  fi
  if ! grep -Fq 'Usage:' <<< "$output"; then
    echo "Release audit usage fixture missed its diagnostic:" >&2
    echo "$output" >&2
    exit 1
  fi
}

swiftpm_success_message='SwiftPM release library and module metadata contain no test hooks.'
xcode_success_message='Xcode release library and module metadata contain no test hooks.'
leak_message='Test hooks leaked into SwiftPM release library or its module metadata.'
xcode_leak_message='Test hooks leaked into Xcode release library or its module metadata.'

expect_usage_failure

fixture_path="$(new_fixture unknown-audit-mode)"
if unknown_mode_output="$(
  expect_failure \
    unknown-audit-mode unknown "$fixture_path" 'unused diagnostic' 2>&1
)"; then
  unknown_mode_status=0
else
  unknown_mode_status=$?
fi
if (( unknown_mode_status != 2 )); then
  echo "Unknown audit mode returned status $unknown_mode_status instead of 2:" >&2
  echo "$unknown_mode_output" >&2
  exit 1
fi
if ! grep -Fq 'Unknown release-layout audit mode: unknown' \
  <<< "$unknown_mode_output"
then
  echo "Unknown audit mode fixture missed its diagnostic:" >&2
  echo "$unknown_mode_output" >&2
  exit 1
fi

fixture_path="$(new_fixture swiftpm-current)"
add_swiftpm_current_layout "$fixture_path"
expect_success swiftpm-current swiftpm "$fixture_path" "$swiftpm_success_message"

fixture_path="$(new_fixture swiftpm-legacy)"
add_swiftpm_legacy_layout "$fixture_path"
expect_success swiftpm-legacy swiftpm "$fixture_path" "$swiftpm_success_message"

fixture_path="$(new_fixture swiftpm-interface-only)"
add_swiftpm_interface_layout "$fixture_path"
expect_success \
  swiftpm-interface-only swiftpm "$fixture_path" "$swiftpm_success_message"

fixture_path="$(new_fixture swiftpm-package-interface-leak)"
add_swiftpm_interface_layout "$fixture_path"
printf 'environmentApplicationForTesting\n' \
  >> "$fixture_path/AutoTableChartsUI.package.swiftinterface"
expect_failure \
  swiftpm-package-interface-leak swiftpm "$fixture_path" "$leak_message"

fixture_path="$(new_fixture swiftpm-private-interface-leak)"
add_swiftpm_interface_layout "$fixture_path"
printf 'sessionForTesting\n' \
  >> "$fixture_path/AutoTableChartsUI.private.swiftinterface"
expect_failure \
  swiftpm-private-interface-leak swiftpm "$fixture_path" "$leak_message"

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

fixture_path="$(new_fixture swiftpm-sidecars-without-module)"
for target_name in AutoTableCharts AutoTableChartsUI; do
  add_swiftpm_current_object "$fixture_path" "$target_name"
done
add_swiftpm_current_module "$fixture_path" AutoTableCharts
add_swiftpm_current_module_sidecars "$fixture_path" AutoTableChartsUI
expect_failure \
  swiftpm-sidecars-without-module swiftpm "$fixture_path" \
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

fixture_path="$(new_fixture swiftpm-documentation-leak)"
add_swiftpm_current_layout "$fixture_path"
printf 'sessionForTesting\n' \
  >> "$fixture_path/Modules/AutoTableChartsUI.swiftmodule/arm64-apple-macos.swiftdoc"
expect_failure swiftpm-documentation-leak swiftpm "$fixture_path" "$leak_message"

fixture_path="$(new_fixture swiftpm-abi-leak)"
add_swiftpm_current_layout "$fixture_path"
printf 'sessionForTesting\n' \
  >> "$fixture_path/Modules/AutoTableChartsUI.swiftmodule/arm64-apple-macos.abi.json"
expect_failure swiftpm-abi-leak swiftpm "$fixture_path" "$leak_message"

fixture_path="$(new_fixture swiftpm-legacy-module-leak)"
add_swiftpm_legacy_layout "$fixture_path"
printf 'sessionForTesting\n' >> "$fixture_path/AutoTableChartsUI.swiftmodule"
expect_failure swiftpm-legacy-module-leak swiftpm "$fixture_path" "$leak_message"

fixture_path="$(new_fixture swiftpm-legacy-documentation-leak)"
add_swiftpm_legacy_layout "$fixture_path"
printf 'sessionForTesting\n' >> "$fixture_path/AutoTableChartsUI.swiftdoc"
expect_failure \
  swiftpm-legacy-documentation-leak swiftpm "$fixture_path" "$leak_message"

fixture_path="$(new_fixture swiftpm-legacy-abi-leak)"
add_swiftpm_legacy_layout "$fixture_path"
printf 'sessionForTesting\n' >> "$fixture_path/AutoTableChartsUI.abi.json"
expect_failure swiftpm-legacy-abi-leak swiftpm "$fixture_path" "$leak_message"

fixture_path="$(new_fixture xcode-missing-products)"
expect_failure \
  xcode-missing-products xcode "$fixture_path" \
  'Could not find Xcode build products under'

fixture_path="$(new_fixture xcode-current)"
add_xcode_layout "$fixture_path"
expect_success xcode-current xcode "$fixture_path" "$xcode_success_message"

fixture_path="$(new_fixture xcode-interface-only)"
add_xcode_interface_layout "$fixture_path"
expect_success xcode-interface-only xcode "$fixture_path" "$xcode_success_message"

fixture_path="$(new_fixture xcode-flat-interface-leak)"
add_xcode_flat_layout "$fixture_path"
xcode_release="$(xcode_release_path "$fixture_path")"
printf 'sessionForTesting\n' \
  >> "$xcode_release/AutoTableChartsUI.swiftinterface"
expect_failure \
  xcode-flat-interface-leak xcode "$fixture_path" "$xcode_leak_message"

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

fixture_path="$(new_fixture xcode-sidecars-without-module)"
for target_name in AutoTableCharts AutoTableChartsUI; do
  add_xcode_object "$fixture_path" "$target_name"
done
add_xcode_module "$fixture_path" AutoTableCharts
add_xcode_module_sidecars "$fixture_path" AutoTableChartsUI
expect_failure \
  xcode-sidecars-without-module xcode "$fixture_path" \
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

fixture_path="$(new_fixture xcode-interface-leak)"
add_xcode_layout "$fixture_path"
xcode_release="$(xcode_release_path "$fixture_path")"
printf 'sessionForTesting\n' \
  >> "$xcode_release/AutoTableChartsUI.swiftmodule/arm64-apple-ios.swiftinterface"
expect_failure xcode-interface-leak xcode "$fixture_path" "$xcode_leak_message"

fixture_path="$(new_fixture xcode-documentation-leak)"
add_xcode_layout "$fixture_path"
xcode_release="$(xcode_release_path "$fixture_path")"
printf 'sessionForTesting\n' \
  >> "$xcode_release/AutoTableChartsUI.swiftmodule/arm64-apple-ios.swiftdoc"
expect_failure xcode-documentation-leak xcode "$fixture_path" "$xcode_leak_message"

fixture_path="$(new_fixture xcode-abi-leak)"
add_xcode_layout "$fixture_path"
xcode_release="$(xcode_release_path "$fixture_path")"
printf 'sessionForTesting\n' \
  >> "$xcode_release/AutoTableChartsUI.swiftmodule/arm64-apple-ios.abi.json"
expect_failure xcode-abi-leak xcode "$fixture_path" "$xcode_leak_message"

# Mixed layouts must audit the flat siblings as well as the directory contents.
for audit_mode in swiftpm xcode; do
  fixture_name="$audit_mode-mixed-clean"
  fixture_path="$(new_fixture "$fixture_name")"
  if [[ "$audit_mode" == swiftpm ]]; then
    add_swiftpm_mixed_layout "$fixture_path"
    success_message="$swiftpm_success_message"
    expected_leak_message="$leak_message"
  else
    add_xcode_mixed_layout "$fixture_path"
    success_message="$xcode_success_message"
    expected_leak_message="$xcode_leak_message"
  fi
  expect_success "$fixture_name" "$audit_mode" "$fixture_path" "$success_message"

  for artifact_suffix in \
    swiftinterface private.swiftinterface package.swiftinterface swiftdoc abi.json
  do
    fixture_name="$audit_mode-mixed-$artifact_suffix-leak"
    fixture_path="$(new_fixture "$fixture_name")"
    if [[ "$audit_mode" == swiftpm ]]; then
      add_swiftpm_mixed_layout "$fixture_path"
      module_stem="$fixture_path/Modules/AutoTableChartsUI"
    else
      add_xcode_mixed_layout "$fixture_path"
      module_stem="$(xcode_module_stem "$fixture_path" AutoTableChartsUI)"
    fi
    printf 'sessionForTesting\n' >> "$module_stem.$artifact_suffix"
    expect_failure \
      "$fixture_name" "$audit_mode" "$fixture_path" "$expected_leak_message"
  done
done

for interface_suffix in swiftinterface private.swiftinterface package.swiftinterface; do
  fixture_name="xcode-flat-$interface_suffix-only"
  fixture_path="$(new_fixture "$fixture_name")"
  add_xcode_flat_layout "$fixture_path" Release-iphoneos direct "$interface_suffix"
  expect_success "$fixture_name" xcode "$fixture_path" "$xcode_success_message"
done

for artifact_suffix in \
  private.swiftinterface package.swiftinterface swiftdoc abi.json
do
  fixture_name="xcode-flat-$artifact_suffix-leak"
  fixture_path="$(new_fixture "$fixture_name")"
  add_xcode_flat_layout "$fixture_path"
  module_stem="$(xcode_module_stem "$fixture_path" AutoTableChartsUI)"
  printf 'sessionForTesting\n' >> "$module_stem.$artifact_suffix"
  expect_failure "$fixture_name" xcode "$fixture_path" "$xcode_leak_message"
done

fixture_path="$(new_fixture xcode-flat-sidecars-without-module)"
add_xcode_object "$fixture_path" AutoTableCharts
add_xcode_object "$fixture_path" AutoTableChartsUI
add_xcode_flat_interface "$fixture_path" AutoTableCharts
add_xcode_flat_sidecars "$fixture_path" AutoTableChartsUI
expect_failure \
  xcode-flat-sidecars-without-module xcode "$fixture_path" \
  'Could not find Xcode Release modules for AutoTableChartsUI under'

fixture_path="$(new_fixture xcode-nested-interface-only-leak)"
add_xcode_interface_layout "$fixture_path"
module_stem="$(xcode_module_stem "$fixture_path" AutoTableChartsUI)"
printf 'sessionForTesting\n' \
  >> "$module_stem.swiftmodule/arm64-apple-ios.swiftinterface"
expect_failure \
  xcode-nested-interface-only-leak xcode "$fixture_path" "$xcode_leak_message"

fixture_path="$(new_fixture xcode-second-architecture-leak)"
add_xcode_layout "$fixture_path"
module_stem="$(xcode_module_stem "$fixture_path" AutoTableChartsUI)"
printf 'sessionForTesting\n' \
  > "$module_stem.swiftmodule/x86_64-apple-ios-simulator.private.swiftinterface"
expect_failure \
  xcode-second-architecture-leak xcode "$fixture_path" "$xcode_leak_message"

for framework_layout in module interface flat; do
  fixture_name="xcode-framework-$framework_layout"
  fixture_path="$(new_fixture "$fixture_name")"
  case "$framework_layout" in
    module) add_xcode_layout "$fixture_path" Release-iphoneos framework ;;
    interface) add_xcode_interface_layout "$fixture_path" Release-iphoneos framework ;;
    flat) add_xcode_flat_layout "$fixture_path" Release-iphoneos framework ;;
  esac
  expect_success "$fixture_name" xcode "$fixture_path" "$xcode_success_message"

  # A clean direct module must not hide a leak in another module location.
  add_xcode_layout "$fixture_path"
  module_stem="$(
    xcode_module_stem "$fixture_path" AutoTableChartsUI Release-iphoneos framework
  )"
  if [[ "$framework_layout" == flat ]]; then
    leak_path="$module_stem.private.swiftinterface"
  else
    leak_path="$module_stem.swiftmodule/arm64-apple-ios.swiftinterface"
  fi
  printf 'sessionForTesting\n' >> "$leak_path"
  expect_failure \
    "$fixture_name-with-direct-leak" xcode "$fixture_path" "$xcode_leak_message"
done

for macos_layout in module flat; do
  fixture_name="xcode-macos-$macos_layout"
  fixture_path="$(new_fixture "$fixture_name")"
  if [[ "$macos_layout" == module ]]; then
    add_xcode_layout "$fixture_path" Release
  else
    add_xcode_flat_layout "$fixture_path" Release
  fi
  expect_success "$fixture_name" xcode "$fixture_path" "$xcode_success_message"
  module_stem="$(xcode_module_stem "$fixture_path" AutoTableChartsUI Release)"
  printf 'sessionForTesting\n' >> "$module_stem.swiftinterface"
  expect_failure "$fixture_name-leak" xcode "$fixture_path" "$xcode_leak_message"
done

for leak_configuration in Release Release-iphoneos; do
  fixture_name="xcode-multiple-configurations-$leak_configuration-leak"
  fixture_path="$(new_fixture "$fixture_name")"
  add_xcode_layout "$fixture_path" Release
  add_xcode_layout "$fixture_path" Release-iphoneos
  module_stem="$(
    xcode_module_stem "$fixture_path" AutoTableChartsUI "$leak_configuration"
  )"
  printf 'sessionForTesting\n' \
    >> "$module_stem.swiftmodule/arm64-apple-ios.swiftinterface"
  expect_failure "$fixture_name" xcode "$fixture_path" "$xcode_leak_message"
done

for artifact_suffix in swiftdoc abi.json; do
  fixture_name="xcode-orphan-$artifact_suffix-leak"
  fixture_path="$(new_fixture "$fixture_name")"
  add_xcode_layout "$fixture_path"
  add_xcode_flat_sidecars "$fixture_path" AutoTableChartsUI Release-iphonesimulator
  module_stem="$(
    xcode_module_stem "$fixture_path" AutoTableChartsUI Release-iphonesimulator
  )"
  printf 'sessionForTesting\n' >> "$module_stem.$artifact_suffix"
  expect_failure "$fixture_name" xcode "$fixture_path" "$xcode_leak_message"
done

fixture_path="$(new_fixture 'xcode derived data with spaces')"
add_xcode_flat_layout "$fixture_path" Release-iphoneos framework
add_xcode_layout "$fixture_path" Release
expect_success xcode-path-with-spaces xcode "$fixture_path" "$xcode_success_message"

fixture_path="$(new_fixture xcode-ignored-configurations)"
add_xcode_layout "$fixture_path"
for ignored_configuration in Debug Debug-iphoneos ReleaseCandidate; do
  add_xcode_layout "$fixture_path" "$ignored_configuration"
  ignored_release="$(xcode_release_path "$fixture_path" "$ignored_configuration")"
  printf 'sessionForTesting\n' >> "$ignored_release/AutoTableChartsUI.o"
  printf 'sessionForTesting\n' \
    >> "$ignored_release/AutoTableChartsUI.swiftmodule/arm64-apple-ios.swiftinterface"
done
expect_success \
  xcode-ignored-configurations xcode "$fixture_path" "$xcode_success_message"

fixture_path="$(new_fixture xcode-only-ignored-configurations)"
for ignored_configuration in Debug Debug-iphoneos ReleaseCandidate; do
  add_xcode_layout "$fixture_path" "$ignored_configuration"
done
expect_failure \
  xcode-only-ignored-configurations xcode "$fixture_path" \
  'Could not find an Xcode Release AutoTableCharts.o under'

fixture_path="$(new_fixture xcode-only-ignored-ui-module)"
add_xcode_object "$fixture_path" AutoTableCharts
add_xcode_object "$fixture_path" AutoTableChartsUI
add_xcode_module "$fixture_path" AutoTableCharts
for ignored_configuration in Debug Debug-iphoneos ReleaseCandidate; do
  add_xcode_module "$fixture_path" AutoTableChartsUI "$ignored_configuration"
done
expect_failure \
  xcode-only-ignored-ui-module xcode "$fixture_path" \
  'Could not find Xcode Release modules for AutoTableChartsUI under'

fixture_path="$(new_fixture xcode-exact-target-names)"
add_xcode_layout "$fixture_path"
xcode_release="$(xcode_release_path "$fixture_path")"
printf 'sessionForTesting\n' > "$xcode_release/AutoTableChartsUIExtra.o"
printf 'sessionForTesting\n' > "$xcode_release/AutoTableChartsUIExtra.swiftinterface"
expect_success \
  xcode-exact-target-names xcode "$fixture_path" "$xcode_success_message"

echo "Verified SwiftPM and Xcode release-library artifact discovery."
