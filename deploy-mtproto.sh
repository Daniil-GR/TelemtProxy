#!/usr/bin/env bash
# Standalone Telemt MTProto/FakeTLS installer (no Telegram WEB Proxy).
# Ubuntu 24.04; default external SNI www.booking.com; optional own HTTPS site.
set -Eeuo pipefail

PORT=443
MASK_DOMAIN="www.booking.com"
TEMP_INSTALLER=""
TEMP_EDGE_HELPER=""
TEMP_EDGE_CIDRS=""
EDGE_MODE=0
SELFSTEAL_MODE=0
SYNLIMIT=0
SYNLIMIT_LINE=""
MASK_PORT=8443
MASK_SETTINGS=""
TLS_CERT=""
TLS_KEY=""
CERT_MANAGER=""
CERT_TOKEN=""
MANAGED_TLS=0
SHARED_TLS=0
SITE_ZIP=""
EDGE_OWNED_INSTALL=0
cleanup() {
  local status=$?
  if (( status != 0 && EDGE_MODE == 1 && EDGE_OWNED_INSTALL == 1 )); then
    systemctl disable --now telemt-gcore-refresh.timer >/dev/null 2>&1 || true
    systemctl stop telemt >/dev/null 2>&1 || true
    echo '[ERROR] Fresh Edge Telemt stopped after installation failure; SSH and routing are unchanged.' >&2
  fi
  if [[ -n "$SITE_ZIP" ]]; then rm -f "$SITE_ZIP"; fi
  if [[ -n "$TEMP_INSTALLER" ]]; then rm -f "$TEMP_INSTALLER"; fi
  if [[ -n "$TEMP_EDGE_HELPER" ]]; then rm -f "$TEMP_EDGE_HELPER"; fi
  if [[ -n "$TEMP_EDGE_CIDRS" ]]; then rm -f "$TEMP_EDGE_CIDRS"; fi
}
on_error() {
  local code=$?
  echo "[ERROR] Installation failed (line $1, exit code $code)." >&2
  exit "$code"
}
trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

usage() {
  cat <<'USAGE'
Usage: sudo bash deploy-mtproto.sh [DOMAIN] [OPTIONS]

Options:
  --synlimit            Enable built-in Telemt SYN limiting (iptables; replaces external SYN FIX)
  --selfsteal           MTProto + own Nginx HTTPS runner site, without WEB Proxy
  --nginx               Alias for --selfsteal
  --cert-manager URL   HTTPS origin of certificate manager (with --selfsteal)
  --cert-token KEY     Per-node access key (omit for hidden prompt)
  --tls-cert FILE       Existing trusted TLS fullchain (with --selfsteal)
  --tls-key FILE        Matching private key; renewal managed externally
  --edge-proxy          MTProto for Gcore Edge Proxy (TCP 443, PROXY protocol v1/v2)
  --domain FQDN         Domain for public tg://proxy link (or positional DOMAIN)
  --hello HEX           Reuse existing hello secret (exactly 32 HEX characters)
  --hello-secret HEX    Same as --hello
  --ad-tag HEX          Sponsor tag from @MTProxybot (exactly 32 HEX characters)
  -h, --help            Show this message

Missing credentials are requested securely on a terminal.
Empty hello input generates a new secret; empty ad_tag leaves it disabled.
Command-line secrets may be visible in shell history and process listings.
USAGE
}

DOMAIN=""
SECRET=""
AD_TAG=""
HELLO_FLAG_SET=0
AD_TAG_FLAG_SET=0

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --synlimit)
      SYNLIMIT=1
      SYNLIMIT_LINE='synlimit = "iptables"'
      shift
      ;;
    --selfsteal|--nginx)
      SELFSTEAL_MODE=1
      shift
      ;;
    --edge-proxy)
      EDGE_MODE=1
      shift
      ;;
    --domain|--hello|--hello-secret|--ad-tag|--tls-cert|--tls-key|--cert-manager|--cert-token)
      option="$1"
      if (($# < 2)); then
        echo "Missing value for $option" >&2
        exit 1
      fi
      value="$2"
      case "$option" in
        --domain)
          if [[ -n "$DOMAIN" ]]; then echo 'Domain specified more than once.' >&2; exit 1; fi
          DOMAIN="$value"
          ;;
        --hello|--hello-secret)
          if ((HELLO_FLAG_SET)); then echo 'hello secret specified more than once.' >&2; exit 1; fi
          if [[ -z "$value" ]]; then echo 'Empty hello flag is invalid; omit it for generation.' >&2; exit 1; fi
          SECRET="$value"
          HELLO_FLAG_SET=1
          ;;
        --cert-manager)
          [[ -z "$CERT_MANAGER" && -n "$value" && "$value" != --* ]] || { echo 'Invalid or duplicate --cert-manager.' >&2; exit 1; }
          CERT_MANAGER="$value"
          ;;
        --cert-token)
          [[ -z "$CERT_TOKEN" && "$value" =~ ^[A-Za-z0-9_-]{43}$ ]] || { echo 'Invalid or duplicate --cert-token.' >&2; exit 1; }
          CERT_TOKEN="$value"
          ;;
        --tls-cert)
          [[ -z "$TLS_CERT" && -n "$value" ]] || { echo 'Invalid or duplicate --tls-cert.' >&2; exit 1; }
          TLS_CERT="$value"
          ;;
        --tls-key)
          [[ -z "$TLS_KEY" && -n "$value" ]] || { echo 'Invalid or duplicate --tls-key.' >&2; exit 1; }
          TLS_KEY="$value"
          ;;
        --ad-tag)
          if ((AD_TAG_FLAG_SET)); then echo 'ad_tag specified more than once.' >&2; exit 1; fi
          if [[ -z "$value" ]]; then echo 'Empty ad_tag flag is invalid; omit it for no tag.' >&2; exit 1; fi
          AD_TAG="$value"
          AD_TAG_FLAG_SET=1
          ;;
      esac
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$DOMAIN" ]]; then
        echo 'Domain specified more than once.' >&2
        exit 1
      fi
      DOMAIN="$1"
      shift
      ;;
  esac
done

if [[ -n "$CERT_MANAGER$CERT_TOKEN" ]]; then
  if (( SELFSTEAL_MODE != 1 )) || [[ -z "$CERT_MANAGER" || -n "$TLS_CERT$TLS_KEY" ]]; then
    echo 'Managed TLS requires --selfsteal --cert-manager URL and cannot use TLS file flags.' >&2
    exit 1
  fi
  MANAGED_TLS=1
  SHARED_TLS=1
fi
if [[ -n "$TLS_CERT$TLS_KEY" ]]; then
  if (( SELFSTEAL_MODE != 1 )) || [[ -z "$TLS_CERT" || -z "$TLS_KEY" ]]; then
    echo '--tls-cert and --tls-key must be supplied together with --selfsteal.' >&2
    exit 1
  fi
  SHARED_TLS=1
fi
if (( SYNLIMIT == 1 && EDGE_MODE == 1 )); then
  echo '--synlimit is not supported with --edge-proxy (shared Edge source IPs).' >&2; exit 1
fi
if (( SELFSTEAL_MODE == 1 && EDGE_MODE == 1 )); then
  echo '--selfsteal cannot be combined with --edge-proxy.' >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo 'Run as root: sudo bash deploy-mtproto.sh [proxy.example.org]' >&2
  exit 1
fi

if [[ -z "$DOMAIN" ]]; then
  if [[ ! -r /dev/tty ]]; then
    echo 'Specify a domain via --domain FQDN or positional argument.' >&2
    exit 1
  fi
  read -r -p 'Введите домен для MTProto-ссылки (например, lt.example.org): ' DOMAIN </dev/tty
fi
DOMAIN="${DOMAIN,,}"
if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ||
      "$DOMAIN" != *.* || "$DOMAIN" == *..* || ${#DOMAIN} -gt 253 ]]; then
  echo 'Invalid domain. Example: lt.example.org' >&2
  exit 1
fi
if (( SELFSTEAL_MODE == 1 )); then
  MASK_DOMAIN="$DOMAIN"
  MASK_SETTINGS=$'mask_host = "127.0.0.1"\nmask_port = 8443\nmask_proxy_protocol = 0'
fi
if [[ ! -f /etc/os-release ]]; then
  echo 'Supported OS: Ubuntu 24.04 only.' >&2
  exit 1
fi
. /etc/os-release
if [[ "$ID" != ubuntu || "$VERSION_ID" != '24.04' ]]; then
  echo 'Supported OS: Ubuntu 24.04 only.' >&2
  exit 1
fi
if (( MANAGED_TLS == 1 )); then
  python3 - "$CERT_MANAGER" <<'MANAGER_URL'
import sys
from urllib.parse import urlsplit
p = urlsplit(sys.argv[1])
if p.scheme != "https" or not p.hostname or p.username or p.password or p.query or p.fragment or p.path not in ("", "/"):
    sys.exit("Certificate manager must be an HTTPS origin without credentials, path or query")
MANAGER_URL
fi
if (( SHARED_TLS == 1 && MANAGED_TLS == 0 )); then
  [[ "$TLS_CERT" == /* && "$TLS_KEY" == /* && -s "$TLS_CERT" && -s "$TLS_KEY" ]] || {
    echo 'Supply absolute paths to the existing certificate and key.' >&2; exit 1;
  }
  command -v openssl >/dev/null || { echo 'Install openssl to validate TLS files.' >&2; exit 1; }
  python3 - "$TLS_KEY" <<'KEY_CHECK'
import os, stat, sys
s = os.stat(sys.argv[1])
if not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o077:
    sys.exit('TLS private key must be root-owned with permissions 600 or stricter.')
KEY_CHECK
  openssl x509 -in "$TLS_CERT" -noout -checkend 86400 >/dev/null || {
    echo 'TLS certificate is invalid or expires within 24 hours.' >&2; exit 1;
  }
  openssl verify -purpose sslserver -verify_hostname "$DOMAIN" -untrusted "$TLS_CERT" "$TLS_CERT" >/dev/null || {
    echo 'TLS certificate chain or hostname validation failed.' >&2; exit 1;
  }
  CERT_PUB="$(openssl x509 -in "$TLS_CERT" -noout -pubkey | openssl pkey -pubin -outform DER | openssl dgst -sha256)"
  KEY_PUB="$(openssl pkey -in "$TLS_KEY" -passin pass: -pubout -outform DER | openssl dgst -sha256)"
  [[ "$CERT_PUB" == "$KEY_PUB" ]] || { echo 'TLS certificate and key do not match.' >&2; exit 1; }
  echo '[OK] Existing TLS certificate validated.'
fi
if [[ -e /etc/telemt/telemt.toml || -e /opt/mtpr-simple/main.sh ]]; then
  echo 'Existing Telemt/MEKOPR detected. This installer is for a fresh VPS.' >&2
  exit 1
fi
for program in curl python3 ss ip getent; do
  command -v "$program" >/dev/null 2>&1 || {
    echo "Missing $program. Install it before proceeding." >&2
    exit 1
  }
done
if ss -lntH | awk -v port="$PORT" '$4 ~ (":" port "$") {found=1} END {exit !found}'; then
  echo "TCP port $PORT is occupied. The installer will not replace another service." >&2
  exit 1
fi

if (( SELFSTEAL_MODE == 1 )); then
  for p in 80 "$MASK_PORT"; do
    if ss -lntH | awk -v port="$p" '$4 ~ (":" port "$") {found=1} END {exit !found}'; then
      echo "TCP port $p is occupied; refusing to replace an existing service." >&2
      exit 1
    fi
  done
  if command -v nginx >/dev/null 2>&1 || [[ -e /etc/nginx/sites-available/default || -e /var/www/telemtproxy || -L /var/www/telemtproxy ]]; then
    echo 'Existing Nginx/site detected. --selfsteal is for a fresh VPS.' >&2
    exit 1
  fi
fi

if (( EDGE_MODE == 1 )); then
  echo '[1/5] Preparing Gcore Edge mode (public DNS may point to Edge IP or be absent)...'
  for path in /etc/telemt/gcore-edge-cidrs.json /usr/local/lib/telemtproxy/gcore-edge.py /etc/systemd/system/telemt-gcore-firewall.service; do
    [[ ! -e "$path" ]] || { echo "Existing Edge setup: $path. Use a fresh VPS." >&2; exit 1; }
  done
  TEMP_EDGE_HELPER="$(mktemp)"
  TEMP_EDGE_CIDRS="$(mktemp)"
  curl -fsSL --retry 3 --max-time 30 https://raw.githubusercontent.com/Daniil-GR/TelemtProxy/main/gcore-edge.py -o "$TEMP_EDGE_HELPER"
  EXPECTED_EDGE_SHA256="e278c2418af4a04baa86925387c22751981084d27477219439415fe167fa8034"
  [[ "$(sha256sum "$TEMP_EDGE_HELPER" | awk '{print $1}')" == "$EXPECTED_EDGE_SHA256" ]] || {
    echo 'Edge helper checksum mismatch. Download the current installer again.' >&2; exit 1;
  }
  python3 "$TEMP_EDGE_HELPER" fetch > "$TEMP_EDGE_CIDRS"
  PUBLIC_IP="$(curl -4 -fsS --connect-timeout 5 --max-time 12 https://api.ipify.org)"
  python3 - "$PUBLIC_IP" <<'IP_CHECK'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
assert ip.version == 4 and ip.is_global
IP_CHECK
  echo '[OK] Official Gcore network list validated. No API token required.'
else
echo '[1/5] Checking domain resolution...'
PUBLIC_IP="$(curl -4 -fsS --connect-timeout 5 --max-time 12 https://api.ipify.org)"
DNS_IPS="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"
if [[ -z "$DNS_IPS" ]]; then
  echo "No DNS A record for $DOMAIN. Create the record before installing." >&2
  exit 1
fi
MATCHED=0
while IFS= read -r candidate; do
  if [[ "$candidate" == "$PUBLIC_IP" ]] || ip -o -4 addr show | awk -v ip="$candidate" '$4 ~ ("^" ip "/") {found=1} END {exit !found}'; then
    MATCHED=1
    break
  fi
done <<< "$DNS_IPS"
if (( MATCHED == 0 )); then
  echo "DNS for $DOMAIN resolves to: $DNS_IPS" >&2
  echo "Neither matches outgoing public IP $PUBLIC_IP nor a local interface address." >&2
  echo 'Check Floating IP assignment and DNS before installing.' >&2
  exit 1
fi
echo "[OK] $DOMAIN resolves to this VPS (including assigned Floating IPs)."

fi

echo '[2/5] Selecting hello secret and sponsor ad_tag...'
# Provided CLI values take priority. Read only missing credentials from the
# terminal, and never echo them. Avoid putting reusable secrets on the CLI
# when shell history/process-list exposure is a concern.
if { : </dev/tty; } 2>/dev/null; then
  if ((HELLO_FLAG_SET == 0)); then
    if ! read -r -s -p 'Секрет hello (32 HEX, Enter = создать новый): ' SECRET </dev/tty; then
      echo 'Failed to read hello secret.' >&2
      exit 1
    fi
    printf '\n'
  fi
  if ((AD_TAG_FLAG_SET == 0)); then
    if ! read -r -s -p 'ad_tag (32 HEX, Enter = без тега): ' AD_TAG </dev/tty; then
      echo 'Failed to read ad_tag.' >&2
      exit 1
    fi
    printf '\n'
  fi
else
  if ((HELLO_FLAG_SET == 0)); then
    echo '[INFO] No terminal or --hello flag: generating a new secret.'
  fi
  if ((AD_TAG_FLAG_SET == 0)); then
    echo '[INFO] No terminal or --ad-tag flag: leaving sponsor tag empty.'
  fi
fi
if [[ -z "$SECRET" ]]; then
  SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
  echo '[OK] Generated a new hello secret.'
else
  if [[ ! "$SECRET" =~ ^[[:xdigit:]]{32}$ ]]; then
    echo '[ERROR] hello secret must contain exactly 32 hexadecimal characters (without dd/ee).' >&2
    exit 1
  fi
  SECRET="${SECRET,,}"
  echo '[OK] Reusing the supplied hello secret.'
fi
if [[ -n "$AD_TAG" ]]; then
  if [[ ! "$AD_TAG" =~ ^[[:xdigit:]]{32}$ ]]; then
    echo '[ERROR] ad_tag must contain exactly 32 hexadecimal characters.' >&2
    exit 1
  fi
  AD_TAG="${AD_TAG,,}"
  echo '[OK] Reusing the supplied ad_tag.'
else
  echo '[INFO] No sponsor ad_tag selected.'
fi

if (( SELFSTEAL_MODE == 1 )); then
  echo '[SELFSTEAL] Installing Nginx and Certbot for the local HTTPS site...'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  if (( SHARED_TLS == 1 )); then
    apt-get install -y -qq nginx ca-certificates openssl
  else
    apt-get install -y -qq nginx certbot ca-certificates openssl
  fi
  # Nginx may be automatically started with its default port 80 server.
  systemctl stop nginx
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    if (( SHARED_TLS == 0 )); then ufw allow 80/tcp; fi
    ufw allow 443/tcp
  fi
  install -d -m 755 /var/www/telemtproxy
  SITE_ZIP="$(mktemp --suffix=.zip)"
  base64 -d > "$SITE_ZIP" <<'RUNNER_SITE_ZIP'
UEsDBBQAAAAIACE0V11V7EBazAAAADUBAAALAAAAZmF2aWNvbi5zdmddkN1uwyAMRu/7FJZ3ncaQ
Ea1T6MWut4fIEhLoKESElWpPP+8nlTYJGfvoOzKiWy8zXM8+rBptzstjXZdS9qXZxzTXkohqTiBc
nClP8aqRgKC954PHHUCXzJChuDFbjczAGjfb/NMnjgu+J+e9xjvqaaBXrL+9pc8WRo0vgkBIK6Tn
RioQVEnF43MjQamPmzw1k5rEP/ksW5aBi4K2EmpLhxgMwppTfDPsPoyH9kAbqH5fq27Au2CGftGY
4nsY/+BTdGHjvLv7+ozj7hNQSwMEFAAAAAgAITRXXUm5X+3iDQAALCgAAAcAAABnYW1lLmpzrRrb
jtvG9T1fMYaTiBQv5p3UamXDdtzUreMYzqZJULQwRY4kZilSJamVFHuBJAVaFClQ5KEvBYoC/YL0
kjSN2/QXtL/QL+mZCymSonY3bX3ZJWfOOXPu58wMBUFEo9vo+SuI/uktc4zyIouCojfkY0Ga5AVa
Zf5igTM0QmEaLOc4KdQpLh7EmDze2zwMhd7Un+Oe2EQL/OTMzy/DygOc7KMVa8BhyATjfpoUeF0I
PSNsg+ZBmuEH8eVLAEgbb4zz4nI0AtHGmuM896f4MjQO0sYsoiK+gk+OeUIg99BB/OthA2Ab2Q+K
KE0uQ2YQO7wYg8kBQdc0TUYzeLIMeJhm6TIJ4c00bBnFPtAeIa2OlBd+QdTTy7Afbnoysw+BgscF
xgTZcAG5iObUnWAcx/4ipzMNUukYiAUxJu7z45/IKFzS5cjjIvY3FPs52hwREmfwE53XsYn16hSL
bAPQfPTxcj7GmRCngR+/U6QZ6I2o5GGB50IvWyYJzhRmfvTiBdLYzyE6B5csghkSsIien3PCzJFU
YiDqpglZgAwOX2kYIfOp5gRfRmMadD6S0Ft+MVPJTDqHSOwjYYwU5LfMtyDBwAKVws/9teAYMhio
j1TDaDs2SHVKENYy2sBaK/g/k2EyTjMW7CS81EkUg+ibmNiGzg2r4ac4KATGGTG3sBZlVHvdlK8B
jmJhvGq+zkRxuLMEF51JnvDliXmIkihWHiVCAoLohjrwBh5RgmW6tqfalm0OUYaLZZYAuMLAJ3Ga
ZkLB1uCLTJYJc/AM59FHGDRV5rOKAViNZzBi53tEjiiZ3o8jMBcVt1Iion6fqasoLGZD6vqZOsPR
dFYMd/4/I6p3B8PWOuEiK+Wag1yrCAy7UkN8FgX4SbTG8VMfGCXepMvIqK3JUx1dtKTAtE2MDGRB
YA7DeGkCzUqgHUGwZY6LE/CtfJJmcwGmZRIp8K96rODPu1SJi4Ymq0AeNgK2iurKNQ3Hlnc6MC2N
e6qpE9co417f8cqiWd0wevztjL01k8BwlwSGTcb2IrCn9Q5LBzSzpnRc3uEugRE+wEd6wzLpq7Mo
DDFJo0W2xEOeVdvLbv9w8fHFZ9uvtt9uv0H//sXnl3Dx4XK+aDARTZDA1r8xqnEAICXHDfUolZLd
Ac3SEEXqwBbLqIEYaZCu9HwbcPX6wuhaZGvg4FJIIHEcMTNF6Bh58EuSRGoidbHMZ8Lz9dFiLYiS
4UAqOmLBo1jggOsjkvMERddsWfcggYQbPuLZskJH4miC2Ziqe7JqGeJ5jYPzg0olXcjbZ5DcG75b
GjWFmd6wqXDq17dpym7qhBcLCjDszvPvQK+UTAWKW9cPqzaN+pJ31Re5QUE8UGJQzZC8j9hzu99t
v9h+c/Hpxc8vPkHbf4H3/Wn75fav26+3L2/UBGZtRAv52faP2z8Dxt/RxScXv7z4/OLTI/Tqcyr2
uYq2vwfKX23/sf0a6F58zCm/RIQ0Gftm++3FJ9t/br8G5F+zpV9e/EZGQOlTAnzxGSH72fYvgPsF
MAgwX1786uJzRN63f1Of7bjbC7SJH+d4N38g4n5bIwch9/KywF/4q6SjQBR+HFcptSzHx5Cz7N3q
VSrizo3WR2glmZDsaNo+YkTuIFNHR8h0IXJopq7GXQfGbQgF+n5+SfItouBUCItrpQYe6hVgmZsl
6PaK4V72rhXREhLCWxOvSqfcTelkHfi7JP+y3yEz+qDW+PWRqXriXkE4I0IYmq2R6lZ01AuYrkCb
IO10p5EcelmdqQcYKVDKaI8emzjmxLgn7QoazVW6Shpjmi6Bo0orqgNmNzXtFtWXWF+OZlLmhOkY
pZOdmzWTUTpW14QrpvGmtNW2aeZn7wMrNOnqoGAy8AEM8NRrW1KpA2lQRyfiMeRjupAEP6hTKy56
/XVGVzItyJJ0thr8AOA5bacakywNAPkwwLMwAH6aAqFaqobsCvuF0zpLXbmv3gzsohFa1gKIpKS5
TAnvvI26jRSz7ti0LoG6H/jBTAhZKxqCUkmkqOG6DxqFhw1/3/B3Uoe4N6DzFjWyo6JEGQeUJse4
fWl3NfaDU6agjlyUnxIPJQ1cAEop8KMowX72ZuaHpFsVNJn8Zdj1SDzdqH4Y3ietPJScBcCh3k1d
0wPd6ZG+pj2v2iaBMAaWaeqdEDqZHxgD3fF7rday2j2MAKu1cyDsrfYZZMJN43TVkO4piOXHlXSr
vupZ5Uazr1qQRkmC3R/dZRzYocK8aYu1xcgybXX0bk7sMPR9h+pjH0IHCDzAlo817bC8BO+aAjfw
YHULm2O7x5DHeBolT0AGcH7y7mcBld2USyEdS66ypeMSETVXhJXo4JOHfYMhkhXqu5dbt9BTXGQp
WpD9BgridBnmzWxD+7YR6dqOdX1Ie7Z6YNLdM91yClFft1zYevFE3XfF14SVpHuaKLFf5aviaMM2
iU2VePqCangS7AKFSLJEsF+jV6IbVmG8lscb2dUYmNh3NdkEg4zHAfY1G/c6USTdBSzFkw2OJxli
H2qOB5i+PQ4Hht0w5XldTW9Ay5/RIx0/R2RzHkDkTvKD9rNCR7PGvaaB63akA3NoMU9SoSNCQfdU
9WtQ/fp4tJK84VoaeU3lsyg5G1V74zXYXdclKCxiX9ekxrhhi327UQaAgRjSBTCwrhzJNaUzRdf7
VcRwHyqpkMjp1FGN2s69u3yurSl34OmOdYmmvqOiHKIoZ99L54BY+FFSb0C4cEGaC8JackBDoD9P
pIcrJtffPpxB4TRLFPuNmtGpUsWylXLp/6/ixoZvuH5v+D/qS9eIwkjB7eLecJpepHli32kxdS3u
SQxFUIWhQYS2IilyGS38DJpbf73HG8k30bFhdqeb9YjmGl1Xykxj8txiQKrhv6sBKOvtZLMZceFc
heUBHaLF208Za3kDaYWkB3vgeJYLyYFPKKa8kUzZpFmnPSmRSQOmrPpkd1p5k50RkYTCUnBepAne
pRVGsjQjFI6Zwh97NwPLd9xxnfQetEuq1DiwvEvAJCgXlFXf8ix70uvwFWYPT7vMHq5ZmYN2nVCT
bGYEjVtFK62iNYOmbhJJN3lu1iH3C6W0im53pHRiH6MsAfqgfJZcse/JKHrNhH1U76YXuo497h1R
AV3nsC0eQ+OE8iiepUtcwN7Jj9NkiooZRuO0KNJ5d12MjnfnmatbkBr2lcTS9HoU9Um/vxnNFN1U
ansrLjA4ax+Etg4IaoPtN2Am3eNd2jXONwLYBC9zcrjL+mq+++xoIws8f795TLiWKCw0S44I29B0
UUYNP99suROlIAOYZMsloiczWMWmfBvYMPb9kCICEkGFbYhV4ugk8JzJwHP1A0jKgCIxeNro6Yas
a1etBdpv4BmuPJCrF+tKVivpFKNBx4HFbSB1bXzJa+CDunZ8mFdLoTWxScYpX6ju3DHUB+dqLlqE
rBod4yoyBLNmbmJn07SC+s1b5cSKVRUVhkJWpgnUsiamtcPY9+O5nwdp0bH9WfMNLIRV1UBCC2rb
SKp28O1dhR+RHXi1vz9GitWsZ7l/htuFFzr5sR/fjRczH5AJiTtI1W10RE4rDtdofaBP9AM1Gsdx
BPmSNBRemYttGUjf0d0jUwdlald38GQsw1A1sj2WuRj0uSBH+zHsoNhqUJ/qRyjlpWNcjJhkiqpb
IFpV+cvMTlKUqll2a/2UnDUJBL+jM7jvL0Y9Kh1TAxn7QRol1WA9B9/N5s2eOofdySmudkXaRA8n
OzrvETcatdg50AspENqKKw5rHYtimrKit4YgG7ARtnRbqweoG2abOFiwSdq0ZcU+RBpkf4SnO9nZ
9WgWhZiY5I5ztG8LE/Y915McEh5AN8TUBwojL5tGc8awqxntv1DE/lq6J3UvZZjlhHFQ5aCXe2m4
ORhg2ljXdO3APpk6GN11K5DkyX/bIv/0S4Kp6XCmY2uW2XY44zCzD9ZQcsFymzj6CIfoRyjEeTRN
0CRL57SXyJeLRRzBVJxO08Pbf3NiT/QOsRoYlWfrIJzWMrC2N6bJBzr3DtgOklpl2CBOc1zT89V6
HIx9zzfaerSu575OByutYKuBdHtrR44k55gQW61rHF6roJJvJAu8hda0iYHdwOk6VlgrxgAgbbJP
8DohD3dnC9gStooaVS70obWjolm9ktaOAlsXU+zSalR9TNFqQVkjuIIuRZcdRzZdekdcDnogpkHD
c8c2wnGOW6fK1SkqPxilx6icTKqu5ZSf38r8WLX7qIBsK/gVODnDJqeiIldnCERCdUPV/iybjn3B
sEhCgVw6sORXn++uBGR2dto3VFM8F5/VFiqbhcPtxCTz51Cv8v1+IqzuyskiAKKQ71bEW+TTFvpd
h4xUzawfSZH5UZE3rXGj+naG3U6RO4DynmZY2r1+sJ/hny3BQ+8m0Zxc+iffoxxSPi+RYwb7xhjf
pS8CPmtfAeEzcsyOz9TCz6ZQT+ovLIbz7kGh5/fE/dsidgW9Y4f9Lj+V8MPwwRmI/Ah2+TjBmdBb
QJUvcBamq6QnN5itiPBLun3cIAZ1ARZZs4Lmn0jsQ5/iDV+FqqH2kVqpCTVIQ34d9s7CD3CPC74b
vptl6erdxf7ED/HmvY67M06X6zZKyNlGgMGfv3/y1iP+vRShdeunwsPHT949eXHy4P2Tu08f3H1x
792Tk7cfi6/eUgui7J36C3/6mFi846LuTF1kmAj9Bp74y7hox/8NgMjwAvsQSi07Xa0+9ikMaI89
VAjlJzLD3RcPVzvquUjW/g9QSwMEFAAAAAgAITRXXaKcXbVsBgAA9A8AAAoAAABpbmRleC5odG1s
rVdPc9NGFL/zKRZxLFr9seXEGdmdKW1P6bSH9NBemLW0sUVkSSOtHcIpCZ1ygGmgLVOmLZT00Csp
ITQQknyF1Vfgk/S9lWzLjiFNh8SJtU/v7b59v/d7+9a9/OmX11a++eoz0hP9sH3JxS8Ssqjb0tKB
hgLO/PYlQtw+F4x4PZZmXLS0r1c+1xc1YkxeRazPW9ow4OtJnAqNeHEkeASq64Evei2fDwOP62pw
lQRRIAIW6pnHQt6y5kwkerzPdS8O47Qy1xWzaXLTm6Pv88xLg0QEcVTRl7tyT77Kt4l8nm/KA/kG
/o7h94TIE/k3Psjn8ijfkQf5dr6V71Ai7xN5CuLXco+83fwZBwfK9DTfzO/KfbA5JPhWvgaT22B0
9/LIHRGIkLcvuqZrFHY4QxhEayTlYUsLPNyI2Ehgb0GfdbmRDbsf3eyHGumlfLWlGatsiEoU5CMH
JuaZ2Ah51uNcjPWViHpZprRdo0DW7cT+hjL2gyHxQpZlLS2B9TQUghjVeFoMprX6LF3TCEsDpoes
g6vK32Bz+/Ik35aH8lQbGYEZOEkwNz6Jb7Y0k5ikUYdPad0LfJ9HgHk64BUjMEu5J0iRQBqq93jQ
7YniOYWZLPheDcIQM4OZntnRjCn7hIke8VvaF5ZJLLtn2SE82A6xTN12YLhcs4nj3BpPslpbdVat
d0zStxswCYF/DmnoljOyiuKIayQTabwGYF1Z9JuNpjkS6KX3zlgAIHGPJUCweBD5U+IbcRCN5BUf
XMS+GsyERSMQMsHEINPabtB2jaBNIPv+lE/lfflYPpJ/YTY/kQ9g8ET+COg8kw/h9a58BlPCJGNU
DYB1PIjYGOICfJ15yKtsBuxdTH55BGQ4rELNxq4NkqIUFAnYEyLJlgxD0D43hlyssWGCKc7SLlaU
6x0oO5BPKn2jOE54xFMSxWDL05SnWlv+Adn1An6RkC+Rg67B5i3ch/KidwZCIIXes/j1Tiwu4oAK
fPvt97+U0YPYQqa/xsIAVL5HgN2Q+hWnXANiWfLIGBGpGPZZMAl/xlWAJ1FP42pEK5zjG7yTxusa
VplfAdSn8gkBZB/Cw2O5JX8vsK2giQy2/kdNAqPJDMkE0o4qVrD+xeukayTzN+UJlk3zfgxlR0Qk
SaEAphsfFMrKYvOqk12Hz7zqVFLeG8A0kbimjqd2pUJYdJHUqKPXaJ1YDWp5OsWqQa26TpsgovWa
btEmXWyGukPtBVBs6jZ1YD1ad1B7ET46dUBmg6bZgO+Q1hZAu9ZYthboAnGo49G6raOUmk1QBoOG
A7bWskMtLFJ0kZo1YlnU9mASC3UdXXmBI2qjE43Gsm3SGjq16NFmTS+eF+rUttFRdHvhW6hDM+UH
f+YmfhXAKjFn8YRsjyP/PEQvVBl2Ia935D9yD93BBCb5VpGf1XpxIl8Rxd5q1ZgqfUbJxJKlZ6mZ
hGxDL2Uz5fCR3Id19pbOUuEQyAX0m6HDOxjehXZGX09ZksDOSOAXEth9DJ2SNqpqgnWCyOeYrjNu
PIY1XgLBDwGhA4I+KIofyCMCjhwVrDzJt5CgqAKu3LtK8jvwDHr5XTJhMPgJ4ZxmpseiIcuUX5nH
8eCbc4S7RqE2ZVnZY2/gz1Kw2n0AxRBT8OlBvr0EGMAJGXXLNQF2rW0CUkrYrhp2eCbA8ClsFre4
KV8slYclmhZvzbJ2F7jPlMr5nrhrHR8On0kgXQMlxCAQsz15WtY/FbWXWBLPzHpWMAt4POQppNYI
y2AIWCdxGAj+nkApyz7PMmzX1B5Hg2kbPAPs6vuVsob/pFo1qP2QEwTpo/a3n9/+GA4A+8wkydQc
/CYGe5xu56XaFtaJQ8URPGxUn1hQFM6d6QQ8Bh7fKbhMpw6N+bGcOe5mhrPxgoNCxP3ppK42VL0g
EqrX+C8cJrjHYxW3QyQ/KpyA79ASwVUCYoMpAvGAyb6D3R0DIzFZyrzB3Y9C8AOdbsmUXwXbVdRZ
WXKKG0FZBlT4R6Eqo5vfLmpcoXJ+oSuGk3bEXY1jUWn4E1wEO4bjEjNVNDaxyClcd4r0hzi8gXgo
sBHfPaL2e4QxkcfU7aQG9gwqpiU5Jw0EzH4CWXQ8CgdGcwb8Ko7oIfbLa9l03/kB+4MVHvJuyvr6
mZ7uvJU+WEdbAcw1JqCUYnwqbrzEx/lIlnpwycMUpzfwPmAUb/GmV1zxgNLqjv8vUEsDBBQAAAAI
ACE0V12Rx++viwgAAL8aAAAJAAAAc3R5bGUuY3NzrVhNj7O6Fd73V1hv9EozVYhsCBCSTdVFpbvo
6qqL6qoLG5vEHQIIzHzcq/73HttgzEdmplJHmiQY+/h8Puexz21dK/THn5D5y+uyboMuv4m7OCNO
25fL8CYI2PWMdjjDAufTYEMb0cJ4kRShyKbxe68Eh3FK2YmevHFZKT2c5knGpuFSVrBfe2X0KSR4
j8IogQ8S7dGBJM923n/M55/RH4jV70Enf5cVaMTqlos2gKHLMOOm7iVM6vK2LsuAiRt9lTXo2N3B
0ts4i9X8w5l9p+1VVmeER41AzeAm5PUGyhKMX2/ji/pVtEVZvwXvZ3STnIvq4rvujF5p+zS45Xl8
VdSVCgp6l+XHGf1SKdHuUS+DjlZd0IlWFnvUfXRK3INe7lFAm6YUgR3Zo7+Cb17+TvNfzfPfQNQe
/fhVXGuB/vHLD1jppIzbMZq/XNu6ryAALeWSlsFVf4tKPYmylE0nUBL/RDH8U4Vi/BOl8c892oVJ
xEKGsP5NMMlJrF/ux6hrT/ycBYP1StXVHlHwd/Am2ItUgaJNcAPPldp7weAV1YKWDW1BhTEAes3w
VlY30B/eKPGuAi7yuqVK1hCQqq7EuODQ0KuARW+Sq9tZh+iJRClu3veDYlMYEe1V7fJBUMiQKdZe
aDPSQNo0lHOTSyRr3lFe0nvzFIZabvz6tkfJqXl3oeSya0oKYSxKAUspWFkFEgLTnVEudGgv6N99
p2TxAbbDs053sDwXkInqTUC+oCttzigExV3AxhwGb95BDdCiq0vJh2TSxTFz+wEMfQFPfEcZsxk5
Nq487OLu9QoCRj8cI/1+cKx90CIX/u8UVX233tdskTWPNCiFgu9AO8F4GSpa3C+2KKCKoe6JCcOQ
DDvGc87YMOFt0DCN8VIPOeVCqtePxpgHvwZ29MiPlF5GP+ta6EFByO2LxZIb5fWbzhuMSAze32U5
p1nkdrQpFNBcZ+WGBx57PjwZZ3q2Rm5gtC3xbFvsdOj6pqlbNdXKLo85yUE1U1LSlol5hw5h95Wc
800D2CTt7QZKP1wEpSIDW+MGdbX3/PTcpWmWpmLl2AjPywpqCcB8FRYShxFh39ndqT1bH4YRDU9T
XnvaQrJplS0gBK3188krAgCcGiYYwDHRm+Lm9LZIEOEJCeDnM9LQgIgvTHwI1tZvIG+V1KvkD03y
j8HMTizL8kU+nDAesWzCBG+/G5nvNOhpEesQTpiFNHJMfeyA07VCwQEfY1ePToUQe3A6VV7PlFSl
8NKRQZtg+LLWh6Ran9DqEyZGn1GiAVqMwnRVC3E67ZYrulFr+jN4a3Vx6c8NuB0D+Qkehl70mKr8
XWRlvPa/4Ptctom732WO6QT1LrmwyaMNTFq5JCVz91ow98vf/C7q9q4hYO8VyfBst1iDBFjuKsvJ
GMSVVIl/PgWhids0/9C0EqL4saxFw//SKbFJGmJyWsOrzlK040fBWR7imeQO+n7FN2STSMvKPemC
wW6nyxYknXIan9i24IcwwsNslg7z7khSrzvah5GRQMYA9zKIBQtccE+OR+hg6So46iqIjho/Jquv
9C5MKjceP2nqMaytgCDIVzG1tqHSiYGkKNUyY4xNiEZiuqSli/zS6tsPrBXxHaHTnrYTVdyRYxiS
DOhfwtMkJs9zkTOvx1ESH2kcX5ZcxjFqCTMHUmd/ivFN32k8EiW4cSQcI5fceKXqPr8NTQJIIK1k
01vBjoj3baezpKmlKUufOPkeP59poTzHu3L+8eMyLg7EKwx14+ZTbCgDI3rdO2XVCeUZWmtkVR+a
5xCNA+8BK0XFg3vNoXi7ulCBocabbF00AmyprsEyGATHXFz3PpGGCMY6D3ZFUYQo0T/9tybQxFFX
64CcVq8GVMdsxpoDeScdeHJIyMo6f5k6Zs91im944PdAVlyzxVCHZ+S20GkKkBkatBo6sH34jDwZ
dAeC16qvefR2jMbSlGXptaniWCSCbiJGTnnKeBIv2QkmGSG0WEG0bR4TuyFDRX2L5ukteFs3QSFL
pRVhZd8+nXyUNZp3qq2r64JRGI49EAPr3cTtAkcFSeG76u9wlsoBxSmDwmj1QDeX/cL4RsMbou3s
OmqzsLejz6L0lt65bdnEpsY28zQYn1A+Ia3o1Gih6/8Yf3I0yAnH7OQ0MskWe3hsylsjIRj2VbJG
Xuk+SCXnomsrQW34Dem3IAP+znfRdfaMusUr7xR4y3R2PR4Niue0zJ904aEARZolPfu5pYvYHiF8
k1P/7DjLWQJs7Jjn23mec86KOHqUhJlJwmWyn2ws/S5u+LzuZWiHU5zjLOLbfriFjoPb7p8sqmTo
kZntkZFhiqllrmuaGmmWurVN4+/iJQvnpzzbqMoFK042pf5m2+i//EqZAYyZbNvcNw+EX+KZC3uk
wx6uDkxYkEQ3le80YJMoeBVPc8RNHWKt2bBv1uEGVeGBKKUspfHco4/WTsfGGdeKIxGyTQsSnoVJ
MYWvwEUksiUX1vCwbPCe47CzbGF39qma28QwOsZR5M6XRV0btrC8G5w1gzB+fIP0f7w78q5zBrUW
NbCKkDtwEppk4eMaGMQd9LcmIS+P7nusDg/3YTxnLPtEKv30KuIvd8ElRU8eZiaG6Dq2Nt7qzcKR
pBut2Qv99u1XlHj83j646aubn+my69Ec785mEzm+vGhx+utTskck1hU3u3tY3hhECyXNhccge5qF
17P8Y747scf2xD7f3JzQhwO0d7Il8eoIvJ0tTtD8JDRFJlqoZziopT5WwkBK7IPBPMsY3JKBB859
SpbabKzZZGDJep5lUxMCgPx4zZqitbkTW/B7u62rKYWPDtHmq13nmV2zPZg1ArlXTiTDnzrBwZ1h
5Fy2Ind3jf29+oS2z8BwbDGe/fMKb1pRiLYLWsH7XOhj0nj41c9Q72N++RceQzmBqP8CUEsBAhQD
FAAAAAgAITRXXVXsQFrMAAAANQEAAAsAAAAAAAAAAAAAAKSBAAAAAGZhdmljb24uc3ZnUEsBAhQD
FAAAAAgAITRXXUm5X+3iDQAALCgAAAcAAAAAAAAAAAAAAKSB9QAAAGdhbWUuanNQSwECFAMUAAAA
CAAhNFddopxdtWwGAAD0DwAACgAAAAAAAAAAAAAApIH8DgAAaW5kZXguaHRtbFBLAQIUAxQAAAAI
ACE0V12Rx++viwgAAL8aAAAJAAAAAAAAAAAAAACkgZAVAABzdHlsZS5jc3NQSwUGAAAAAAQABADd
AAAAQh4AAAAA
RUNNER_SITE_ZIP
python3 - "$SITE_ZIP" /var/www/telemtproxy <<'PY'
import colorsys, pathlib, random, re, secrets, shutil, sys, tempfile, zipfile
zip_path = pathlib.Path(sys.argv[1]); public = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(zip_path) as z:
    needed=('index.html','style.css','game.js','favicon.svg')
    if not all(n in z.namelist() for n in needed): raise ValueError('Missing site file')
    src={n:z.read(n).decode('utf-8') for n in needed}

rng = random.SystemRandom()
version=secrets.token_hex(7)
html=src['index.html']; css=src['style.css']; js=src['game.js']; svg=src['favicon.svg']
title=rng.choice(('Сайт временно обновляется','Пока мы настраиваем страницу','Небольшой перерыв','Скоро снова онлайн'))
subtitle=rng.choice(('А пока — перепрыгни кактусы!','Попробуй перепрыгнуть все кактусы.','Небольшая игра, пока страница обновляется.'))
html=html.replace('<title>Сайт временно обновляется</title>',f'<title>{title}</title>')
html=html.replace('content="Сайт временно обновляется. А пока — перепрыгни кактусы!"',f'content="{subtitle}"')
# CSS/JS/favicon filenames stay stable; unique cache busting is in the HTML only.
for fn in ('style.css','game.js','favicon.svg'):
    html=html.replace('"/'+fn+'"','"/'+fn+'?v='+version+'"')

# Slight, stable per-install palette change without altering gameplay or layout.
def hue_shift(code, degrees):
    r,g,b=(int(code[i:i+2],16)/255 for i in (1,3,5))
    h,l,s=colorsys.rgb_to_hls(r,g,b)
    r,g,b=colorsys.hls_to_rgb((h+degrees/360)%1,l,s)
    return '#'+''.join(f'{round(v*255):02x}' for v in (r,g,b))
shift=rng.uniform(-10,10)
for color in ('#a7c69b','#aab8a8','#a7d2aa','#253e2b','#263b2b'):
    css=css.replace(color,hue_shift(color,shift))
css+='\n/* asset revision '+secrets.token_hex(12)+' */\n'
js+='\n/* scene revision '+secrets.token_hex(12)+' */\n'
svg=svg.replace('fill="#0a0c0b"',f'fill="{hue_shift("#0a0c0b",shift)}"')
svg=svg.replace('<svg ', '<svg data-r="'+secrets.token_hex(5)+'" ',1)
svg+='\n<!-- '+secrets.token_hex(12)+' -->\n'
html+='\n<!-- '+secrets.token_hex(12)+' -->\n'

# Stage files, then replace; Telemt snapshots them on its subsequent restart.
public.mkdir(parents=True,exist_ok=True)
for name,content in {'index.html':html,'style.css':css,'game.js':js,'favicon.svg':svg}.items():
    (public/name).write_text(content,encoding='utf-8')
    (public/name).chmod(0o644)
print('[OK] Unique site deployed: version',version)
print('[OK] Asset size:',sum((public/n).stat().st_size for n in needed),'bytes')
PY
  rm -f "$SITE_ZIP"
  SITE_ZIP=""
  if (( MANAGED_TLS == 1 )); then
    echo '[SELFSTEAL] Retrieving centrally managed certificate.'
    install -d -m 755 /usr/local/lib/telemtproxy
    TEMP_INSTALLER="$(mktemp)"
    curl -fsSL --retry 3 --max-time 30 \
      https://raw.githubusercontent.com/Daniil-GR/TelemtProxy/b94479671677636161d99dac60706bab3cd60d93/certificate-client.py \
      -o "$TEMP_INSTALLER"
    python3 -m py_compile "$TEMP_INSTALLER"
    install -m 644 "$TEMP_INSTALLER" /usr/local/lib/telemtproxy/certificate-client.py
    rm -f "$TEMP_INSTALLER"
    TEMP_INSTALLER=""
    TELEMTPROXY_CERT_TOKEN="$CERT_TOKEN" python3 /usr/local/lib/telemtproxy/certificate-client.py setup \
      --manager "$CERT_MANAGER" --domain "$DOMAIN"
    unset CERT_TOKEN
    TLS_CERT_PATH=/var/lib/telemtproxy/certificate-client/current/fullchain.pem
    TLS_KEY_PATH=/var/lib/telemtproxy/certificate-client/current/privkey.pem
  elif (( SHARED_TLS == 1 )); then
    echo '[SELFSTEAL] Using supplied TLS certificate; no ACME issuance on this VPS.'
    install -d -m 700 /etc/telemtproxy/shared-tls
    TLS_CERT_PATH=/etc/telemtproxy/shared-tls/fullchain.pem
    TLS_KEY_PATH=/etc/telemtproxy/shared-tls/privkey.pem
    if [[ ! "$TLS_CERT" -ef "$TLS_CERT_PATH" ]]; then install -m 644 "$TLS_CERT" "$TLS_CERT_PATH"; fi
    if [[ ! "$TLS_KEY" -ef "$TLS_KEY_PATH" ]]; then install -m 600 "$TLS_KEY" "$TLS_KEY_PATH"; fi
  else
    echo '[SELFSTEAL] Obtaining ordinary HTTPS certificate (HTTP-01)...'
    certbot certonly --standalone --preferred-challenges http -d "$DOMAIN" \
      --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring
    TLS_CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    TLS_KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  fi
  cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate $TLS_CERT_PATH;
    ssl_certificate_key $TLS_KEY_PATH;
    root /var/www/telemtproxy;
    index index.html;
    access_log off;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  # Ensure the package default site is enabled; never bind public port 443 here.
  if [[ ! -e /etc/nginx/sites-enabled/default ]]; then
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  fi
  nginx -t
  systemctl enable --now nginx
  systemctl is-active --quiet nginx
  if (( SHARED_TLS == 0 )); then
  # Certbot uses standalone port 80 for renewal; Nginx only listens on loopback.
  # Reload the certificate on successful renewal without restarting Telemt.
  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/telemtproxy-nginx-reload.sh <<'HOOK'
#!/bin/sh
set -eu
nginx -t
systemctl reload nginx
HOOK
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/telemtproxy-nginx-reload.sh
  systemctl enable --now certbot.timer
  fi
  SITE_BODY="$(curl -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 15 \
    --resolve "$DOMAIN:8443:127.0.0.1" "https://$DOMAIN:8443/")"
  if [[ "$SITE_BODY" != *'game.js?v='* || "$SITE_BODY" != *'<title>'* ]]; then
    echo '[ERROR] Local Nginx HTTPS site did not return the expected runner game.' >&2
    exit 1
  fi
  echo '[OK] Local HTTPS site verified on 127.0.0.1:8443.'
fi

if (( EDGE_MODE == 1 )); then
  echo '[2/5] Installing Telemt for Gcore (without direct-client SYN FIX)...'
  FIX_ARGS=(-no-fix)
  command -v apt-get >/dev/null || { echo 'apt-get is required.' >&2; exit 1; }
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y iptables ipset
elif (( SYNLIMIT == 1 )); then
  echo '[2/5] Installing Telemt with built-in SYN limiting (no external SYN FIX)...'
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y iptables
  FIX_ARGS=(-no-fix)
else
  echo '[2/5] Installing Telemt (latest stable) and MEKOPR SYN FIX v3...'
  FIX_ARGS=(-fix -fix-type v3)
fi
TEMP_INSTALLER="$(mktemp)"
curl -fsSL --retry 3 --max-time 30 \
  https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/install.sh \
  -o "$TEMP_INSTALLER"
# Upstream may print temporary proxy links. The final configuration below replaces them.
if (( EDGE_MODE == 1 )); then EDGE_OWNED_INSTALL=1; fi
# The intermediate upstream config must not point to itself before the local mask target is installed.
INITIAL_MASK_DOMAIN="$MASK_DOMAIN"
if (( SELFSTEAL_MODE == 1 )); then INITIAL_MASK_DOMAIN="www.booking.com"; fi
bash "$TEMP_INSTALLER" -telemt -domain "$INITIAL_MASK_DOMAIN" -port "$PORT" \
  -version latest "${FIX_ARGS[@]}"
rm -f "$TEMP_INSTALLER"
TEMP_INSTALLER=""

echo '[3/5] Writing the minimal MTProto-only configuration...'
[[ -f /etc/telemt/telemt.toml ]] || {
  echo 'Telemt config not found after upstream installer.' >&2
  exit 1
}
cp -a /etc/telemt/telemt.toml "/etc/telemt/telemt.toml.bak.$(date +%s)"
cat > /etc/telemt/telemt.toml <<EOF
[general]
use_middle_proxy = true
ad_tag = "$AD_TAG"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = ["hello"]
public_host = "$DOMAIN"
public_port = $PORT

[server]
port = $PORT

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[[server.listeners]]
ip = "0.0.0.0"
port = $PORT
$SYNLIMIT_LINE

[censorship]
tls_domain = "$MASK_DOMAIN"
mask = true
$MASK_SETTINGS
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
hello = "$SECRET"
EOF
chown root:telemt /etc/telemt/telemt.toml
chmod 640 /etc/telemt/telemt.toml
python3 - "$DOMAIN" "$MASK_DOMAIN" "$SELFSTEAL_MODE" <<'PY'
import re, sys, tomllib
with open('/etc/telemt/telemt.toml', 'rb') as fp:
    config = tomllib.load(fp)
assert config['general']['links']['public_host'] == sys.argv[1]
assert config['general']['modes']['tls'] is True
assert config['general']['modes']['secure'] is False
assert config['censorship']['tls_domain'] == sys.argv[2]
if sys.argv[3] == '1':
    assert config['censorship']['mask_host'] == '127.0.0.1'
    assert config['censorship']['mask_port'] == 8443
    assert config['censorship']['mask_proxy_protocol'] == 0
else:
    assert 'mask_host' not in config['censorship']
assert list(config['access']['users']) == ['hello']
assert re.fullmatch(r'[0-9a-f]{32}', config['access']['users']['hello'])
assert config['general']['ad_tag'] == '' or re.fullmatch(r'[0-9a-f]{32}', config['general']['ad_tag'])
assert config['server']['port'] == 443
assert 'web' not in config
print('[OK] Minimal FakeTLS configuration and credentials validated.')
PY

if (( EDGE_MODE == 1 )); then
  python3 "$TEMP_EDGE_HELPER" install --cidrs-file "$TEMP_EDGE_CIDRS"
fi

if (( EDGE_MODE == 0 )) && command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow "$PORT/tcp"
fi

if (( SELFSTEAL_MODE == 1 )); then
  install -d -m 755 /etc/systemd/system/telemt.service.d
  cat > /etc/systemd/system/telemt.service.d/10-telemtproxy-nginx.conf <<'UNIT'
[Unit]
Wants=nginx.service
After=nginx.service
UNIT
  systemctl daemon-reload
fi

# Match MEKOPR's Basic optimization profile, preserving its rollback layout.
# Apply after the final Telemt configuration (including any Edge settings) is written.
if (( SYNLIMIT == 1 )); then
  # Telemt owns its firewall rules and needs CAP_NET_ADMIN at startup.
  install -d -m 755 /etc/systemd/system/telemt.service.d
  cat > /etc/systemd/system/telemt.service.d/20-telemtproxy-synlimit.conf <<'SYNUNIT'
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
SYNUNIT
  echo '[INFO] Built-in Telemt SYN limit enabled (iptables).'
else
  echo '[INFO] Built-in Telemt SYN limit disabled.'
fi

echo '[OPT] Applying MEKOPR basic optimization...'
(
  set -Eeuo pipefail
  umask 077
  snapshot=/opt/mtpr-simple/opt-snapshot
  cfg=/etc/telemt/telemt.toml
  sysctl_file=/etc/sysctl.d/99-custom.conf
  limits=/etc/systemd/system/telemt.service.d/limits.conf
  if [[ -e "$snapshot" || -L "$snapshot" ]]; then
    echo '[ERROR] Existing MEKOPR optimization snapshot; refusing to overwrite it.' >&2
    exit 1
  fi
  install -d -m 700 "$snapshot"
  if [[ -f "$sysctl_file" ]]; then
    cp -a "$sysctl_file" "$snapshot/sysctl.conf"
  else
    touch "$snapshot/sysctl.absent"
  fi
  if [[ -f "$limits" ]]; then
    cp -a "$limits" "$snapshot/limits.conf"
  else
    touch "$snapshot/limits.absent"
  fi
  install -m 600 "$cfg" "$snapshot/telemt.toml"
  printf '%s\n' "$cfg" > "$snapshot/telemt.path"
  date '+%Y-%m-%d %H:%M:%S' > "$snapshot/created_at"
  python3 - "$cfg" <<'BASIC_OPT'
import pathlib, re, sys, tomllib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
c = tomllib.loads(s)
if "max_connections" in c["server"]:
    s, count = re.subn(r"(?m)^max_connections[ \t]*=.*$", "max_connections = 16384", s)
    assert count == 1
else:
    s, count = re.subn(r"(?m)^\[server\][ \t]*$", "[server]\nmax_connections = 16384", s)
    assert count == 1
# The upstream menu updates client_handshake only if already present.
s = re.sub(r"(?m)^client_handshake[ \t]*=.*$", "client_handshake = 15", s)
assert tomllib.loads(s)["server"]["max_connections"] == 16384
p.write_text(s)
BASIC_OPT
  install -d -m 755 /etc/systemd/system/telemt.service.d
  cat > "$limits" <<'OPT_LIMITS'
[Service]
LimitNOFILE=65535
OPT_LIMITS
  chmod 644 "$limits"
  cat > "$sysctl_file" <<'OPT_SYSCTL'
net.ipv4.tcp_fastopen=3
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.core.netdev_max_backlog=65535
fs.file-max=2097152
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_keepalive_time=45
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=3
OPT_SYSCTL
  chmod 644 "$sysctl_file"
  modprobe tcp_bbr 2>/dev/null || true
  # Do not reapply unrelated sysctl configuration on the host.
  if ! sysctl -p "$sysctl_file"; then
    echo '[WARN] Kernel refused one or more basic optimization settings; review output.' >&2
  fi
  systemctl daemon-reload
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == bbr &&
        "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" == fq &&
        "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || true)" == 3 ]]; then
    echo '[OK] Basic optimization applied: BBR, fq, TCP Fast Open.'
  else
    echo '[WARN] Basic optimization only partially applied; kernel settings differ.' >&2
  fi
)

echo '[4/5] Restarting Telemt and waiting for TCP 443...'
if ! systemctl restart telemt; then
  systemctl status telemt -n 30 --no-pager >&2 || true
  journalctl -u telemt -n 60 --no-pager >&2 || true
  exit 1
fi
READY=0
DEADLINE=$((SECONDS + 30))
while (( SECONDS < DEADLINE )); do
  if systemctl is-active --quiet telemt &&
     ss -lntp | awk '$4 ~ /:443$/ && /telemt/ {found=1} END {exit !found}'; then
    READY=1
    break
  fi
  sleep 1
done
if (( READY == 0 )); then
  echo '[ERROR] Telemt did not open port 443 within 30 seconds.' >&2
  systemctl status telemt -n 30 --no-pager >&2 || true
  journalctl -u telemt -n 60 --no-pager >&2 || true
  exit 1
fi
echo '[OK] Telemt service active and TCP 443 is listening.'

if (( SELFSTEAL_MODE == 1 )); then
  # A real HTTPS request through the public MTProto listener must reach Nginx.
  SITE_BODY="$(curl -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 15 \
    --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/")"
  if [[ "$SITE_BODY" != *'game.js?v='* || "$SITE_BODY" != *'<title>'* ]]; then
    echo '[ERROR] HTTPS through Telemt did not return the expected site.' >&2
    exit 1
  fi
  curl -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/game.js" -o /dev/null
  curl -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/style.css" -o /dev/null
  echo '[OK] HTTPS through Telemt verified: certificate, game and CSS/JS.'
  if (( MANAGED_TLS == 1 )); then
    python3 /usr/local/lib/telemtproxy/certificate-client.py enable
  fi
fi

if (( EDGE_MODE == 1 )); then
  echo '[OK] Gcore Edge configuration ready. Full Telegram data transfer must be checked through an active Gcore mapping.'
fi

echo '[5/5] Generating domain-based Telegram link...'
MASK_HEX="$(printf '%s' "$MASK_DOMAIN" | od -An -tx1 | tr -d ' \n')"
LINK="tg://proxy?server=$DOMAIN&port=$PORT&secret=ee$SECRET$MASK_HEX"
umask 077
printf '%s\n' "$LINK" > /root/telemt-mtproto-link.txt
cat <<EOF

================== READY: MTPROTO ONLY ==================
Domain:       $DOMAIN
Port:         $PORT/TCP
User:         hello
FakeTLS SNI:  $MASK_DOMAIN
Telemt:       $(telemt --version 2>/dev/null | head -1 || true)
Telegram:     $LINK

Stored link:  /root/telemt-mtproto-link.txt
Config:       /etc/telemt/telemt.toml
MEKOPR:       mekopr
=========================================================
Note: this is MTProto (tg://proxy), not WEB (tg://webproxy).
No Telegram WEB listener was configured.
Sponsor ad_tag: ${AD_TAG:-not set}
To preserve the same public Telegram link after an IPv4 change,
reuse the previous hello secret and domain (and keep port/SNI unchanged).
EOF

if (( SELFSTEAL_MODE == 1 )); then
  echo "HTTPS site: https://$DOMAIN/"
  if (( MANAGED_TLS == 1 )); then
    echo 'Managed TLS: automatic refresh via telemtproxy-certificate-client.timer.'
    echo 'Status: python3 /usr/local/lib/telemtproxy/certificate-client.py status'
  elif (( SHARED_TLS == 1 )); then
    echo 'Nginx: 127.0.0.1:8443; TLS renewal is managed externally.'
    echo 'Update /etc/telemtproxy/shared-tls/{fullchain.pem,privkey.pem} and reload Nginx after validation.'
  else
    echo 'Nginx: 127.0.0.1:8443; Certbot renewal via systemd timer on port 80.'
  fi
  echo 'Verify actual MTProto connectivity in Telegram using the generated ee link.'
else
  echo 'No Nginx or Certbot configured.'
fi

if (( EDGE_MODE == 1 )); then
  cat <<EOF

================== MTPROTO ДЛЯ EDGE PROXY ==================
Origin VPS: $PUBLIC_IP:443 (TCP)
В Gcore: Generic TCP Server, порт 443/TCP, PROXY protocol V1 (или V2).
После активации укажите выданный Edge IP в A-записи $DOMAIN.
Прямые подключения к VPS:443 запрещены, разрешены только адреса Gcore.
Собственный TLS-сертификат, Nginx и HTTP CDN здесь не нужны.
Сети Gcore обновляются каждые 10 минут; при изменении выполняется
короткий перезапуск Telemt с откатом конфигурации при ошибке.
Журнал: journalctl -u telemt-gcore-refresh.service -u telemt-gcore-firewall.service
Проверка: systemctl status telemt telemt-gcore-refresh.timer
Готовность порта не подтверждает передачу данных: проверьте сообщения
и фотографии в Telegram через Edge IP после настройки Gcore и DNS.
============================================================
EOF
fi
