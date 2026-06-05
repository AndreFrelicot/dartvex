#!/usr/bin/env bash
set -euo pipefail

package_dir="${1%/}"
repo_root="$(git rev-parse --show-toplevel)"
package_name="$(basename "$package_dir")"

relative_path() {
  local from="$1"
  local to="$2"
  local relative

  if relative="$(realpath --relative-to="$from" "$to" 2>/dev/null)"; then
    printf '%s\n' "$relative"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$from" "$to" <<'PY'
import os
import sys

print(os.path.relpath(os.path.realpath(sys.argv[2]), os.path.realpath(sys.argv[1])))
PY
    return
  fi

  printf '%s\n' 'error: realpath --relative-to is unavailable and python3 was not found' >&2
  return 1
}

write_overrides() {
  local target_dir="$1"
  shift

  if [ "$#" -eq 0 ]; then
    return
  fi

  {
    printf '%s\n' 'dependency_overrides:'
    for dependency_name in "$@"; do
      local dependency_path
      dependency_path="$(
        relative_path "$target_dir" "$repo_root/packages/$dependency_name"
      )"
      printf '  %s:\n' "$dependency_name"
      printf '    path: %s\n' "$dependency_path"
    done
  } > "$target_dir/pubspec_overrides.yaml"
}

if [ "$package_name" != "dartvex" ] &&
  grep -qE '^[[:space:]]+dartvex:' "$package_dir/pubspec.yaml"; then
  write_overrides "$package_dir" dartvex
fi

while IFS= read -r nested_pubspec; do
  nested_dir="$(dirname "$nested_pubspec")"
  dependencies=()

  if [ "$package_name" != "dartvex" ]; then
    dependencies+=(dartvex)
  fi
  if grep -qE "^[[:space:]]+$package_name:" "$nested_pubspec"; then
    dependencies+=("$package_name")
  fi

  write_overrides "$nested_dir" "${dependencies[@]}"
done < <(find "$package_dir" -mindepth 2 -name pubspec.yaml -print)
