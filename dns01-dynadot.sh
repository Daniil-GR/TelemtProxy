#!/usr/bin/env bash
# DNS-01 wildcard issuance / renewal for *.vetka.rest using Dynadot + lego >= 5.1.
# Run on ONE trusted certificate manager. Never place Dynadot API credentials on
# every public proxy VPS unless that trade-off is explicitly acceptable.
set -Eeuo pipefail
umask 077

usage() {
  cat <<'HELP'
Usage: sudo bash dns01-dynadot.sh issue|renew --email you@example.org

Requires:
  - lego >= 5.1 (with the Dynadot DNS provider)
  - /etc/telemtproxy/dynadot.env (root-owned 600):
      DYNADOT_API_KEY='...'
      DYNADOT_API_SECRET='...'
  - The server IP authorized in Dynadot API settings.
  - DNS for vetka.rest must be served by Dynadot.

Certificate output:
  /var/lib/telemtproxy/lego-vetka/certificates/_.vetka.rest.crt
  /var/lib/telemtproxy/lego-vetka/certificates/_.vetka.rest.key

The certificate contains only *.vetka.rest (never a named WEB hostname).
Renewals need the API credentials again. On renewal, reloads local Nginx
if running; distribution to other VPSes remains the administrator's task.
HELP
}

if (( EUID != 0 )); then echo 'Run as root.' >&2; exit 1; fi
if [[ $# -eq 0 || "$1" == "--help" || "$1" == "-h" ]]; then usage; exit 0; fi
ACTION="$1"; shift
if [[ "$ACTION" != issue && "$ACTION" != renew ]]; then usage >&2; exit 1; fi
EMAIL=""
while (( $# )); do
  case "$1" in
    --email)
      if (( $# < 2 )) || [[ -z "$2" ]]; then echo 'Missing --email value.' >&2; exit 1; fi
      EMAIL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
if [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  echo 'A valid --email ADDRESS is required for the ACME account.' >&2
  exit 1
fi
command -v lego >/dev/null 2>&1 || {
  echo 'lego CLI is missing. Install the official go-acme/lego v5.1+ binary.' >&2
  exit 1
}
LEGO_MAJOR="$(lego --version 2>&1 | sed -nE 's/.*version ([0-9]+)\.([0-9]+).*/\1/p' | head -1)"
LEGO_MINOR="$(lego --version 2>&1 | sed -nE 's/.*version ([0-9]+)\.([0-9]+).*/\2/p' | head -1)"
if [[ -z "$LEGO_MAJOR" || -z "$LEGO_MINOR" ]] ||
   (( LEGO_MAJOR < 5 || (LEGO_MAJOR == 5 && LEGO_MINOR < 1) )); then
  echo 'lego 5.1 or newer is required for Dynadot DNS.' >&2
  exit 1
fi

ENV_FILE=/etc/telemtproxy/dynadot.env
STORAGE=/var/lib/telemtproxy/lego-vetka
[[ -s "$ENV_FILE" ]] || { echo "Create $ENV_FILE with API credentials, root-owned mode 600." >&2; exit 1; }
python3 - "$ENV_FILE" <<'PY'
import os, stat, sys
s = os.stat(sys.argv[1])
if not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o077:
    sys.exit('Dynadot API credentials file must be root-owned with mode 600.')
PY
# Trusted root-owned config. Keep it away from GitHub, shell history and logs.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
if [[ -z "${DYNADOT_API_KEY:-}" || -z "${DYNADOT_API_SECRET:-}" ]]; then
  echo 'Both DYNADOT_API_KEY and DYNADOT_API_SECRET must be configured.' >&2
  exit 1
fi
install -d -m 700 "$STORAGE"
CRT="$STORAGE/certificates/_.vetka.rest.crt"
KEY="$STORAGE/certificates/_.vetka.rest.key"
if [[ "$ACTION" == issue && ( -s "$CRT" || -s "$KEY" ) ]]; then
  echo 'Certificate files already exist. Run renew instead; original key will be preserved.' >&2
  exit 1
fi
if [[ "$ACTION" == renew && ( ! -s "$CRT" || ! -s "$KEY" ) ]]; then
  echo 'No existing wildcard certificate. Run issue first.' >&2
  exit 1
fi
OLD_FINGERPRINT=""
if [[ -s "$CRT" ]]; then
  OLD_FINGERPRINT="$(openssl x509 -in "$CRT" -noout -fingerprint -sha256)"
fi
echo "[INFO] Requesting DNS-01 $ACTION for *.vetka.rest via Dynadot..."
if [[ "$ACTION" == issue ]]; then
  lego --path "$STORAGE" --email "$EMAIL" --accept-tos \
    --dns dynadot --domains '*.vetka.rest' run
else
  lego --path "$STORAGE" --email "$EMAIL" --accept-tos \
    --dns dynadot --domains '*.vetka.rest' renew --days 30
fi
[[ -s "$CRT" && -s "$KEY" ]] || { echo 'Wildcard certificate files not found after lego.' >&2; exit 1; }
openssl x509 -in "$CRT" -noout -checkend 86400 >/dev/null ||
  { echo 'Wildcard cert is about to expire.' >&2; exit 1; }
# A single DNS name avoids creating exact subdomain CT entries.
openssl x509 -in "$CRT" -noout -ext subjectAltName |
  grep -F 'DNS:*.vetka.rest' >/dev/null ||
  { echo 'Obtained cert is not for *.vetka.rest.' >&2; exit 1; }
NEW_FINGERPRINT="$(openssl x509 -in "$CRT" -noout -fingerprint -sha256)"
if [[ "$OLD_FINGERPRINT" != "$NEW_FINGERPRINT" ]] &&
   command -v systemctl >/dev/null && systemctl is-active --quiet nginx; then
  nginx -t && systemctl reload nginx
  echo '[OK] Local Nginx reloaded with the renewed certificate.'
fi
cat <<EOF

[OK] *.vetka.rest DNS-01 certificate ready.
Certificate: $CRT
Private key: $KEY

On the WEB + MTProto VPS, run deploy.sh with:
  --wildcard-cert "$CRT" --wildcard-key "$KEY"

If certificates are issued on a separate manager, securely copy the files
to each VPS first and renew/deploy them before expiry.
EOF
