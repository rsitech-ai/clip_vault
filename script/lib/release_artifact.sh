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

is_allowed_macho_path() {
  local path="$1"
  case "$path" in
    @rpath | @rpath/* | @loader_path | @loader_path/* | @executable_path | @executable_path/* | /usr/lib | /usr/lib/* | /System/Library | /System/Library/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

strip_nonallowlisted_rpaths() {
  local binary="$1"
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if ! is_allowed_macho_path "$path"; then
      /usr/bin/install_name_tool -delete_rpath "$path" "$binary"
    fi
  done < <(binary_rpaths "$binary")
}

assert_allowed_macho_paths() {
  local artifact="$1"
  local kind="$2"
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if ! is_allowed_macho_path "$path"; then
      printf 'Non-allowlisted %s in %s: %s\n' "$kind" "$artifact" "$path" >&2
      return 1
    fi
  done
}

dependencies_from_otool() {
  awk 'NR > 1 && NF > 0 { print $1 }'
}

install_names_from_otool() {
  awk 'NR > 1 && NF > 0 { print $1 }'
}

assert_macho_paths_allowed() {
  local artifact="$1"
  binary_rpaths "$artifact" | assert_allowed_macho_paths "$artifact" "LC_RPATH"
  /usr/bin/otool -L "$artifact" | dependencies_from_otool | \
    assert_allowed_macho_paths "$artifact" "dependency load path"
  /usr/bin/otool -D "$artifact" | install_names_from_otool | \
    assert_allowed_macho_paths "$artifact" "dylib install name"
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

codesign_details() {
  /usr/bin/codesign -dvvv "$1" 2>&1
}

assert_hardened_runtime() {
  local artifact="$1"
  local details
  details="$(codesign_details "$artifact")"
  if ! grep -Eq ' flags=.*\(.*runtime.*\)' <<<"$details"; then
    printf 'Hardened runtime flag is missing from %s.\n' "$artifact" >&2
    return 1
  fi
}

team_identifier_from_codesign_details() {
  awk -F= '$1 == "TeamIdentifier" { print $2; exit }'
}

installer_identity_from_pkg_signature() {
  awk '/^[[:space:]]*1[.] / { sub(/^[[:space:]]*1[.] /, ""); print; exit }'
}

team_identifier_from_identity() {
  printf '%s\n' "$1" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p'
}
