#!/usr/bin/env bash
set -euo pipefail

package_dir="${1%/}"
repo_root="$(git rev-parse --show-toplevel)"
package_name="$(basename "$package_dir")"

relative_path() {
  realpath --relative-to="$1" "$2"
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
      printf '  %s:\n' "$dependency_name"
      printf '    path: %s\n' \
        "$(relative_path "$target_dir" "$repo_root/packages/$dependency_name")"
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
