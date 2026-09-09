#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
cd "$repository_root"

test_hook_pattern='ATC_TEST_HOOKS|TestHooks?|ForTesting'
audit_symbol_files=()
audit_module_files=()

audit_release_artifacts() {
  local artifact_description="$1"
  local release_symbols
  local release_module_strings

  if ! release_symbols="$(nm "${audit_symbol_files[@]}" | swift demangle)"; then
    echo "Could not inspect $artifact_description symbols." >&2
    exit 1
  fi

  if ! release_module_strings="$(
    for module_file in "${audit_module_files[@]}"; do
      strings -a "$module_file"
    done
  )"; then
    echo "Could not inspect $artifact_description module metadata." >&2
    exit 1
  fi

  if grep -E "$test_hook_pattern" <<<"$release_symbols" \
    || grep -E "$test_hook_pattern" <<<"$release_module_strings"
  then
    echo "Test hooks leaked into $artifact_description or its module metadata." >&2
    exit 1
  fi

  echo "$artifact_description and module metadata contain no test hooks."
}

if (( $# == 0 )); then
  audit_scratch_path="$(
    mktemp -d "${TMPDIR:-/tmp}/autotablecharts-release-audit.XXXXXX"
  )"
  cleanup() {
    if [[ -d "$audit_scratch_path" ]]; then
      rm -rf -- "$audit_scratch_path"
    fi
  }
  trap cleanup EXIT

  swift build -c release --scratch-path "$audit_scratch_path"
  release_bin_path="$(
    swift build -c release \
      --scratch-path "$audit_scratch_path" \
      --show-bin-path
  )"
  shopt -s nullglob
  for target_name in AutoTableCharts AutoTableChartsUI; do
    target_symbol_files=("$release_bin_path/$target_name.build"/*.o)
    if (( ${#target_symbol_files[@]} == 0 )); then
      echo "Could not find release-library objects for $target_name." >&2
      exit 1
    fi
    audit_symbol_files+=("${target_symbol_files[@]}")
  done
  shopt -u nullglob

  for module_name in AutoTableCharts AutoTableChartsUI; do
    module_file_count_before=${#audit_module_files[@]}
    release_module_path="$release_bin_path/Modules/$module_name.swiftmodule"
    if [[ -f "$release_module_path" ]]; then
      audit_module_files+=("$release_module_path")
    elif [[ -d "$release_module_path" ]]; then
      while IFS= read -r -d '' artifact; do
        audit_module_files+=("$artifact")
      done < <(
        find "$release_module_path" \
          -type f \
          \( -name '*.swiftmodule' -o -name '*.swiftinterface' \) \
        -print0
      )
    fi
    if (( ${#audit_module_files[@]} == module_file_count_before )); then
      echo "Could not find the release module for $module_name." >&2
      exit 1
    fi
  done

  if (( ${#audit_symbol_files[@]} == 0 )); then
    echo "Could not find release-library objects for the package products." >&2
    exit 1
  fi
  if (( ${#audit_module_files[@]} == 0 )); then
    echo "Could not find the release modules under $release_bin_path/Modules." >&2
    exit 1
  fi

  audit_release_artifacts "SwiftPM release library"
elif (( $# == 2 )) && [[ "$1" == "--xcode-derived-data" ]]; then
  products_root="$2/Build/Products"
  if [[ ! -d "$products_root" ]]; then
    echo "Could not find Xcode build products under $products_root." >&2
    exit 1
  fi

  for target_name in AutoTableCharts AutoTableChartsUI; do
    symbol_file_count_before=${#audit_symbol_files[@]}
    while IFS= read -r -d '' artifact; do
      audit_symbol_files+=("$artifact")
    done < <(
      find "$products_root" \
        -type f \
        -path "*/Release-*/$target_name.o" \
        -print0
    )
    if (( ${#audit_symbol_files[@]} == symbol_file_count_before )); then
      echo "Could not find an Xcode Release $target_name.o under $products_root." >&2
      exit 1
    fi

    module_file_count_before=${#audit_module_files[@]}
    while IFS= read -r -d '' artifact; do
      audit_module_files+=("$artifact")
    done < <(
      find "$products_root" \
        -type f \
        -path "*/Release-*/$target_name.swiftmodule/*.swiftmodule" \
        -print0
    )
    if (( ${#audit_module_files[@]} == module_file_count_before )); then
      echo "Could not find Xcode Release modules for $target_name under $products_root." >&2
      exit 1
    fi
  done

  if (( ${#audit_symbol_files[@]} == 0 )); then
    echo "Could not find Xcode Release package objects under $products_root." >&2
    exit 1
  fi
  if (( ${#audit_module_files[@]} == 0 )); then
    echo "Could not find Xcode Release package modules under $products_root." >&2
    exit 1
  fi

  audit_release_artifacts "Xcode release library"
else
  echo "Usage: $0 [--xcode-derived-data <path>]" >&2
  exit 2
fi
