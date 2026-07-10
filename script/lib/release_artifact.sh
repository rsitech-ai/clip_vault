#!/usr/bin/env bash

rpaths_from_otool() {
  awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  '
}

binary_rpaths() {
  /usr/bin/otool -l "$1" | rpaths_from_otool
}

is_build_host_rpath() {
  local path="$1"
  case "$path" in
    /Applications/Xcode*.app/* | /Users/* | /private/* | /var/folders/* | /Volumes/* | */.build/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

strip_build_host_rpaths() {
  local binary="$1"
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if is_build_host_rpath "$path"; then
      /usr/bin/install_name_tool -delete_rpath "$path" "$binary"
    fi
  done < <(binary_rpaths "$binary")
}

assert_no_build_host_rpaths() {
  local binary="$1"
  local path
  local found=0
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if is_build_host_rpath "$path"; then
      printf 'Forbidden build-host LC_RPATH in %s: %s\n' "$binary" "$path" >&2
      found=1
    fi
  done < <(binary_rpaths "$binary")
  [[ "$found" -eq 0 ]]
}

uuids_from_dwarfdump() {
  awk '$1 == "UUID:" { print toupper($2) }' | sort -u
}

artifact_uuids() {
  /usr/bin/dwarfdump --uuid "$1" | uuids_from_dwarfdump
}

assert_matching_uuids() {
  local executable="$1"
  local dsym="$2"
  local executable_uuids
  local dsym_uuids
  executable_uuids="$(artifact_uuids "$executable")"
  dsym_uuids="$(artifact_uuids "$dsym")"
  if [[ -z "$executable_uuids" || "$executable_uuids" != "$dsym_uuids" ]]; then
    printf 'Executable/dSYM UUID mismatch.\nExecutable: %s\ndSYM:       %s\n' \
      "$executable_uuids" "$dsym_uuids" >&2
    return 1
  fi
}
