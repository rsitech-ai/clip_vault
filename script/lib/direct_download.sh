#!/usr/bin/env bash

validate_developer_id_application_identity() {
  local identity="$1"
  [[ "$identity" =~ ^Developer\ ID\ Application:\ .+\ \([A-Z0-9]{10}\)$ ]] || {
    printf 'Expected a Developer ID Application identity with a 10-character team identifier.\n' >&2
    return 1
  }
}

team_identifier_from_developer_id_identity() {
  printf '%s\n' "$1" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p'
}

notarization_status_from_json() {
  printf '%s' "$1" | /usr/bin/plutil -extract status raw -o - -- -
}

require_accepted_notarization_status() {
  local submission_json="$1"
  local status
  status="$(notarization_status_from_json "$submission_json")" || {
    printf 'Notarization response did not contain a status.\n' >&2
    return 1
  }
  if [[ "$status" != "Accepted" ]]; then
    printf 'Notarization was not accepted (status: %s).\n' "$status" >&2
    return 1
  fi
}
