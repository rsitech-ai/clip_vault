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
  if [[ $# -gt 1 ]]; then
    is_allowed_macho_path_for_artifact "$@"
    return
  fi
  case "$path" in
    @rpath | @rpath/* | @loader_path | @loader_path/* | @executable_path | @executable_path/*)
      return 0
      ;;
    /*)
      is_allowed_system_macho_path "$path"
      return
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_absolute_path() {
  local input="$1"
  local segment
  local normalized=""
  local -a input_segments
  local -a output_segments=()
  local index
  IFS='/' read -r -a input_segments <<<"$input"
  for segment in "${input_segments[@]}"; do
    case "$segment" in
      "" | ".") ;;
      "..")
        if [[ "${#output_segments[@]}" -gt 0 ]]; then
          index=$((${#output_segments[@]} - 1))
          unset 'output_segments[index]'
        fi
        ;;
      *) output_segments+=("$segment") ;;
    esac
  done
  for segment in "${output_segments[@]}"; do
    normalized="$normalized/$segment"
  done
  printf '%s\n' "${normalized:-/}"
}

is_path_within() {
  local path
  local root
  path="$(normalize_absolute_path "$1")"
  root="$(normalize_absolute_path "$2")"
  [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

is_allowed_system_macho_path() {
  local normalized
  normalized="$(normalize_absolute_path "$1")"
  is_path_within "$normalized" "/usr/lib" || \
    is_path_within "$normalized" "/System/Library"
}

is_allowed_macho_path_for_artifact() {
  local path="$1"
  local artifact="$2"
  local kind="${3:-dependency load path}"
  local app_bundle
  local base
  local suffix
  local resolved

  case "$path" in
    /*)
      is_allowed_system_macho_path "$path"
      return
      ;;
    @loader_path | @executable_path)
      [[ "$kind" == "LC_RPATH" ]]
      return
      ;;
    @rpath)
      return 1
      ;;
  esac

  case "$artifact" in
    *.app/*) app_bundle="${artifact%%.app/*}.app" ;;
    *) return 1 ;;
  esac

  case "$path" in
    @executable_path/*)
      base="$app_bundle/Contents/MacOS"
      suffix="${path#@executable_path/}"
      ;;
    @loader_path/*)
      base="$(dirname "$artifact")"
      suffix="${path#@loader_path/}"
      ;;
    @rpath/*)
      suffix="${path#@rpath/}"
      case "/$suffix/" in
        *"//"* | *"/./"* | *"/../"*) return 1 ;;
      esac
      [[ -n "$suffix" ]]
      return
      ;;
    *) return 1 ;;
  esac

  case "/$suffix/" in
    *"//"* | *"/./"*) return 1 ;;
  esac
  [[ -n "$suffix" ]] || return 1
  resolved="$(normalize_absolute_path "$base/$suffix")"
  is_path_within "$resolved" "$app_bundle"
}

strip_nonallowlisted_rpaths() {
  local binary="$1"
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if ! is_allowed_macho_path "$path" "$binary" "LC_RPATH"; then
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
    if ! is_allowed_macho_path_for_artifact "$path" "$artifact" "$kind"; then
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
