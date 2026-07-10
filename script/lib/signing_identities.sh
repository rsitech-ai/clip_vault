#!/usr/bin/env bash

security_identities() {
  security find-identity -v -p "$1"
}

application_signing_identity_from_output() {
  sed -nE 's/.*"((Apple Distribution|Mac App Distribution|3rd Party Mac Developer Application):[^"]*)".*/\1/p' |
    sed -n '1p'
}

installer_signing_identity_from_output() {
  sed -nE 's/.*"((3rd Party Mac Developer Installer|Mac Installer Distribution):[^"]*)".*/\1/p' |
    sed -n '1p'
}

find_application_signing_identity() {
  security_identities codesigning | application_signing_identity_from_output
}

find_installer_signing_identity() {
  security_identities basic | installer_signing_identity_from_output
}
