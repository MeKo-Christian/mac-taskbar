#!/bin/sh
# Creates a self-signed "MacTaskbar Dev" code-signing identity in the login keychain.
# Signing with a stable identity keeps the Accessibility grant valid across rebuilds
# (ad-hoc signatures change with every build). Run once; asks for your login password
# to trust the certificate for code signing.
set -eu

NAME="MacTaskbar Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Identity \"$NAME\" already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=$(openssl rand -hex 16)

cat > "$TMP/cert.cnf" <<EOF
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
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem"

# OpenSSL 3 defaults to PKCS#12 algorithms the macOS keychain cannot import.
LEGACY=""
if openssl version | grep -q "^OpenSSL 3"; then LEGACY="-legacy"; fi
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/cert.p12" -passout "pass:$PASS"

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning | grep "\"$NAME\"" \
    && echo "Done. Run 'make reset-permission', then 'make run' and grant Accessibility once more."
