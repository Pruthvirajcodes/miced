#!/bin/zsh
# Creates a persistent, local code-signing identity for miced.
#
# Ad-hoc signatures pin macOS privacy grants (Accessibility, Camera) to one
# exact build, so every reinstall silently invalidated them. A stable
# certificate gives the app a designated requirement that survives rebuilds:
#   identifier "com.codetorso.miced" and certificate leaf = H"<cert hash>"
#
# The identity lives in a dedicated keychain so codesign never prompts for the
# login keychain password on a Mac without a keyboard. Prints the keychain
# path and certificate SHA-1 as shell assignments for the installer.

set -euo pipefail

SIGN_DIR="$HOME/Library/Application Support/miced/signing"
KEYCHAIN="$SIGN_DIR/miced-signing.keychain-db"
PASSWORD_FILE="$SIGN_DIR/keychain-password"
COMMON_NAME="miced local code signing"
OPENSSL=/usr/bin/openssl

mkdir -p "$SIGN_DIR"
chmod 700 "$SIGN_DIR"

identity_hash() {
    /usr/bin/security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
        | awk -v name="\"$COMMON_NAME\"" 'index($0, name) { print $2; exit }'
}

if [[ ! -f "$KEYCHAIN" ]]; then
    umask 077
    "$OPENSSL" rand -hex 24 > "$PASSWORD_FILE"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $COMMON_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
        -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
    P12_PASS="$("$OPENSSL" rand -hex 16)"
    "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -name "$COMMON_NAME" -passout "pass:$P12_PASS" -out "$WORK/identity.p12"
    /usr/bin/security create-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
    # No auto-lock, so unattended installs never need a password dialog.
    /usr/bin/security set-keychain-settings "$KEYCHAIN"
    /usr/bin/security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
    /usr/bin/security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
        -T /usr/bin/codesign >/dev/null
    /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "$(cat "$PASSWORD_FILE")" "$KEYCHAIN" >/dev/null
fi

/usr/bin/security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
HASH="$(identity_hash)"
if [[ -z "$HASH" ]]; then
    echo "miced signing identity missing from $KEYCHAIN" >&2
    exit 1
fi
echo "MICED_KEYCHAIN='$KEYCHAIN'"
echo "MICED_SIGNING_IDENTITY='$HASH'"
