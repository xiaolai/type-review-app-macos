#!/bin/bash
# Sets CERT_P12 and CERT_P12_PASSWORD, after proving they belong together.
#
# The pair was set by hand once and the password did not match the file. Nothing
# noticed until a release run reached `security import` on a builder, four steps
# and one certificate import later, and reported "MAC verification failed
# during PKCS12 import" -- which is a clear message arriving in an expensive
# place. Everything needed to catch that is available at the moment the secrets
# are set, so it is caught here instead.
#
#   Tools/set-signing-secrets.sh path/to/cert.p12
#
# The password is read from the terminal, never passed as an argument, so it
# does not reach the process list or the shell history.
set -euo pipefail

p12=${1:-}
[ -n "$p12" ] || { echo "usage: $0 path/to/cert.p12" >&2; exit 1; }
[ -f "$p12" ] || { echo "error: no such file: $p12" >&2; exit 1; }

read -r -s -p "password for $(basename "$p12"): " pw
echo

# The check that was missing. `-legacy` because a .p12 exported by Keychain
# Access uses RC2, which OpenSSL 3 declines to read without it -- and its
# refusal looks exactly like a wrong password, so leaving it off would trade
# one confusing failure for another.
if ! openssl pkcs12 -in "$p12" -passin "pass:$pw" -nokeys -legacy -noout 2>/dev/null; then
  echo "error: that password does not open $p12" >&2
  echo "       (in Keychain Access the export asks twice: once for a new" >&2
  echo "        password for the file, once for your login password to read" >&2
  echo "        the private key. This wants the first one.)" >&2
  exit 1
fi

subject=$(openssl pkcs12 -in "$p12" -passin "pass:$pw" -nokeys -legacy 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null || true)
case "$subject" in
  *"Developer ID Application"*) ;;
  *) echo "error: this .p12 does not contain a Developer ID Application certificate" >&2
     echo "       found: ${subject:-nothing}" >&2
     exit 1 ;;
esac
echo "  opens, and carries: $(echo "$subject" | sed 's/.*CN=//; s/,.*//')"

# And that a private key came with it. A certificate on its own imports without
# complaint and then cannot sign anything.
openssl pkcs12 -in "$p12" -passin "pass:$pw" -nocerts -legacy -noout 2>/dev/null \
  || { echo "error: no private key in $p12 — export the key alongside the certificate" >&2; exit 1; }
echo "  private key: present"

base64 -i "$p12" | gh secret set CERT_P12
printf '%s' "$pw" | gh secret set CERT_P12_PASSWORD
echo "  set CERT_P12 and CERT_P12_PASSWORD"
