#!/bin/sh
# Creates a self-signed code-signing identity in the login keychain so
# `make app` produces bundles with a stable designated requirement. With
# ad-hoc signing every rebuild looks like a new app to the Keychain, which
# re-prompts for each stored server token. Run once per machine.
set -eu

NAME="${1:-RocketNative Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "Signing identity \"$NAME\" already exists."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# Transient password only protects the .p12 in transit to `security import`.
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout pass:rocketnative -out "$WORK/identity.p12" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout pass:rocketnative -out "$WORK/identity.p12"

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P rocketnative -T /usr/bin/codesign
echo "Trusting the certificate for code signing (macOS will ask for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "Created signing identity \"$NAME\". Rebuild with: make app"
