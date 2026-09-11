#!/bin/bash
# Creates a self-signed code-signing identity "GearVR Remote Local Signing" in your
# login keychain. build.sh signs with it automatically when present, which keeps the
# app's signature stable across rebuilds, so macOS doesn't revoke its Accessibility
# and Bluetooth permissions every time you rebuild.
#
# The first build afterwards shows a keychain prompt: enter your password and click
# "Always Allow" so later builds sign silently.
set -euo pipefail
NAME="GearVR Remote Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "identity \"$NAME\" already exists"; exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 -nodes \
    -subj "/CN=$NAME" -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -legacy -out "$tmp/id.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -passout pass:tmp
security import "$tmp/id.p12" -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
echo "created \"$NAME\""
